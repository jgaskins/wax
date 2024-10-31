require "anthropic"
require "xml"

module Wax::Commands::AI
  extend self

  Claude = Anthropic::Client.new

  def call(args : Array(String))
    if args.empty?
      STDERR.puts "Must supply a prompt"
      exit 1
    end
    puts "Analyzing the repo to determine how to accomplish this."
    prompt = args.first

    # TODO: Figure out how to reduce the necessary context
    files = Dir["README.md", "src/**/*.cr", "views/**/*.ecr", "spec/**/*_spec.cr", "db/migrations/**/*.sql"].map do |filename|
      FileData.new(
        path: filename.lchop(ENV["PWD"]),
        contents: File.read(filename),
      )
    end

    file_contents = String.build do |str|
      str.puts "We currently have these files:"
      str.puts

      XML.build_fragment str do |xml|
        files.each do |file|
          xml.element "file", path: file.path do
            xml.text file.contents
          end
        end
      end
    end

    puts Claude.messages.create(
      model: Anthropic.model_name(:sonnet),
      # model: Anthropic.model_name(:haiku),
      messages: [
        Anthropic::Message.new(content: Array(Anthropic::MessageContent){
          Anthropic::Text.new(file_contents),
          Anthropic::Text.new(prompt, cache_control: Anthropic::CacheControl.new),
        }),
      ],
      tools: [
        WriteFiles,
        DeleteFiles,
      ],
      max_tokens: 8192, # Try to fit more complex code generation into a single request so we can run fewer requests
      # max_tokens: 4096,
      temperature: 0,
      system: {
        File.read("#{__DIR__}/../../ai/prompts/wax.md"),
        "The current time is #{Time.utc.to_rfc3339(fraction_digits: 9)}",
      }.join("\n\n"),
    ).last
  end

  record FileData, path : String, contents : String do
    include JSON::Serializable
  end

  alias Handler = Anthropic::Tool::Handler

  struct WriteFiles < Handler
    @[JSON::Field(description: "The list of files to write. All files will be written at the same time.")]
    getter files : Array(File)

    struct File
      include JSON::Serializable
      @[JSON::Field(description: "The path of the file to write or rewrite")]
      getter path : String
      @[JSON::Field(description: "The new or updated contents of the file. This must be the complete contents. It must NOT be a fragment or contain any placeholder content.")]
      getter contents : String
    end

    def self.name
      "WriteFiles"
    end

    def self.description
      <<-DESCRIPTION
        Write or rewrite a list of files in the local git repository. You should write as many files as you need to at the same time.
        DESCRIPTION
    end

    def call
      files.each do |file|
        puts "Writing #{file.path}..."
        ::Dir.mkdir_p ::File.dirname(file.path)
        ::File.write file.path, file.contents
      end
      {status: "success"}
    end
  end

  struct DeleteFiles < Handler
    @[JSON::Field(description: "The file paths to delete")]
    getter files : Array(String)

    def self.name
      "DeleteFiles"
    end

    def self.description
      "Delete the given files from the repo"
    end

    def call
      files.each { |file| File.delete file }
      {status: "success"}
    end
  end
end
