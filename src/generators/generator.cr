module Wax::Generators
  module Commands
    def file(path, body, *, executable = false) : Nil
      puts "Writing #{path}..."
      Dir.mkdir_p File.dirname(path)
      File.write path, body

      if executable
        File.chmod path, 0o755
      end
    end

    def error(message : String, exit_code code = 1)
      STDERR.puts message
      exit code
    end
  end

  abstract class Generator
    include Commands

    abstract def type : String
    abstract def call

    def self.for(type : String)
      SUBCOMMANDS[type]
    end

    private macro handle(type)
      SUBCOMMANDS[{{type}}] = {{@type}}
      getter type : String = {{type}}
    end

    SUBCOMMANDS = {} of String => Generator.class
  end
end
