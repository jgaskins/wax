require "anthropic"
require "xml"

module Wax::Commands::AI
  extend self

  Claude = Anthropic::Client.new

  def call(args : Array(String))
    prompt = args.first do
      STDERR.puts "Reading prompt from STDIN"
      STDIN.gets_to_end
    end
    puts "Analyzing the repo to determine how to accomplish this..."

    files = Dir[
      "README.md",
      "src/**/*.cr",
      "views/**/*.ecr",
      "spec/**/*_spec.cr",
      "db/migrations/**/*.sql",
    ].map do |filename|
      FileData.new(path: filename.lchop(ENV["PWD"]))
    end

    file_contents = String.build do |str|
      str.puts "We currently have these files:"
      str.puts

      XML.build_fragment str do |xml|
        files.each do |file|
          unless Wax.config.ai.context.exclude.any? { |excluded_path| file.path.starts_with? excluded_path }
            xml.element "file", path: file.path
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
        FetchFileContents,
        WriteFiles,
        DeleteFiles,
      ],
      max_tokens: 8192,
      temperature: 0,
      system: {
        File.read("#{__DIR__}/../../ai/prompts/wax.md"),
        "The current time is #{Time.utc.to_rfc3339(fraction_digits: 9)}",
      }.join("\n\n"),
    ).last
  end

  record FileData, path : String do
    include JSON::Serializable
  end

  alias Handler = Anthropic::Tool::Handler

  struct FetchFileContents < Handler
    @[JSON::Field(description: "The path of the files whose contents to fetch.")]
    getter paths : Array(String)

    def self.name
      "FetchFileContents"
    end

    def self.description
      <<-DESCRIPTION
        Get the contents of the files at the specified paths. You have the list of files available to you, so you can get the contents of them with this tool to see what's inside them. It can be really useful to fetch files that are similar to ones you need to work on so you can follow existing conventions! For example, when you're working with routes, it can be useful to read a few other route files to see what conventions are in use.
        DESCRIPTION
    end

    def call
      paths.each_with_object({} of String => String) do |path, hash|
        puts "Reading #{path}..."
        hash[path] = File.read(path)
      end
    end
  end

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
        Write or rewrite a list of files in the local git repository. You should write as many files as you need to at the same time. Before modifying any new files, you should read the existing version. You should also read other similar files to ensure you use existing code conventions.
        DESCRIPTION
    end

    def call
      files.each do |file|
        puts "Writing #{file.path}..."
        ::Dir.mkdir_p ::File.dirname(file.path)
        # Claude doesn't always put a newline at the end of the file, so we do
        # it so git and GitHub don't do that annoying "no newline at end of
        # file" thing when rendering the diff.
        ::File.write file.path, "#{file.contents.rstrip}\n"
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
