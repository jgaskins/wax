require "anthropic"
require "xml"
require "log"

module Wax::Commands::AI
  extend self

  Claude = Anthropic::Client.new
  Log    = ::Log.for("wax.ai")

  def call(args : Array(String))
    model = Anthropic.model_name(:sonnet)
    temperature = nil
    OptionParser.parse args do |parser|
      parser.on "-m MODEL", "--model MODEL", "The model to use for this AI command" do |chosen_model|
        model = chosen_model
      end

      parser.on "-t TEMPERATURE", "--temperature TEMPERATURE", "The temperature to pass to the AI model" do |temp|
        temperature = temp.to_f
      end
    end
    prompt = args.first do
      STDERR.puts "Reading prompt from STDIN"
      STDIN.gets_to_end
    end
    puts "Analyzing the repo to determine how to accomplish this..."

    system_prompt = [File.read("#{__DIR__}/../../ai/prompts/wax.md")]
    %w[CLAUDE.md AGENTS.md].each do |file|
      system_prompt << File.read(file) if File.exists? file
    end
    system_prompt << "The current time is #{Time.utc.to_rfc3339(fraction_digits: 9)}"

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

    output = Claude.messages.create(
      model: model,
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

        GitStatus,
        GitLog,
        GitShow,
        GitBlame,
      ],
      max_tokens: 8192,
      temperature: temperature,
      system: system_prompt.join("\n\n"),
    ).last

    puts "-----"
    puts
    puts output
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
      paths.map do |path|
        Log.info &.emit "Reading file", path: path
        if File.exists? path
          {
            path:     path,
            contents: File.read(path),
          }
        else
          {
            path:  path,
            error: "File does not exist",
          }
        end
      end
    end
  end

  struct WriteFiles < Handler
    @[JSON::Field(description: "The list of files to write. All files will be written at the same time. This MUST be an array of file objects (NOT strings!) even when there is only one to be written.")]
    getter files : Array(File)

    struct File
      include JSON::Serializable
      @[JSON::Field(description: "The path of the file to write or rewrite")]
      getter path : String
      @[JSON::Field(description: "The new or updated contents of the file. This must be the complete contents. It MUST NOT be a fragment or contain any placeholder content.")]
      getter contents : String
    end

    def self.name
      "WriteFiles"
    end

    def self.description
      <<-DESCRIPTION
        Write or rewrite a list of files in the local git repository. You should write as many files as you need to at the same time. Before modifying any new files, you must read the existing version. You should also read other similar files to ensure you use existing code conventions.
        DESCRIPTION
    end

    def call
      files.each do |file|
        Log.info &.emit "Writing", path: file.path
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
      files.each do |file|
        Log.info &.emit "Deleting", file: file
        File.delete file
      end
      {status: "success"}
    end
  end

  module Command
    def call
      output = IO::Memory.new
      error = IO::Memory.new

      command = self.command
      Log.info &.emit command.join(' ')
      status = Process.run command, output: output, error: error

      {
        stdout:      output.to_s,
        error:       error.to_s,
        exit_status: status.exit_code,
      }
    end
  end

  struct GitStatus < Handler
    include Command
    @[JSON::Field(description: "Optional paths to check the git status of")]
    getter paths : Array(String) = [] of String

    def self.name
      "GitStatus"
    end

    def self.description
      "Return the git status of the repo, optionally with specific paths"
    end

    def command
      %w[git status --short] + paths
    end
  end

  struct GitLog < Handler
    include Command

    @[JSON::Field(description: "Optional range of commits to segment the log for")]
    getter range : String?
    @[JSON::Field(description: "Optional paths to check the git status of")]
    getter paths : Array(String) = [] of String
    @[JSON::Field(description: "Optional git log format")]
    getter format : String?
    @[JSON::Field(description: "Limit the output to the first <number> commits that would be shown.")]
    getter max_count : Int32?
    @[JSON::Field(description: "Limit the output to the last <number> commits that would be shown.")]
    getter max_count_oldest : Int32?

    def self.name
      "GitLog"
    end

    def self.description
      "Return the git log"
    end

    def command
      command = %w[git log]
      if range = self.range
        command << range
      end
      command.concat paths
      command << "--format=#{format}" if format
      command << "--max-count=#{max_count}" if max_count
      command << "--max-count-oldest=#{max_count_oldest}" if max_count_oldest

      command
    end
  end

  struct GitShow < Handler
    include Command

    @[JSON::Field(description: "SHA for the object to show")]
    getter object_sha : String
    @[JSON::Field(description: "Optional show format")]
    getter format : String?

    def self.name
      "GitShow"
    end

    def self.description
      "Show the given git object"
    end

    def command
      command = %w[git show]
      command << object_sha
      command << "--format=#{format}" if format

      command
    end
  end

  struct GitBlame < Handler
    include Command

    @[JSON::Field(description: "The path of the files to run blame on.")]
    getter path : String
    @[JSON::Field(description: "Range of lines to blame, in `<start>,<end>` format")]
    getter range : String?

    def self.name
      "GitBlame"
    end

    def self.description
      "Run `git blame` on a file"
    end

    def command
      command = %w[git blame]
      command << path
      command << "-L=#{range}" if range

      command
    end
  end
end
