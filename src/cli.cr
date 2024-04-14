require "option_parser"
require "levenshtein"

require "./commands/generate"

module Wax
  class CLI
    enum Command
      Generate
      G
    end

    def self.call(args = ARGV)
      new.call args
    end

    def call(args = ARGV)
      OptionParser.parse args do |parser|
        parser.unknown_args do
          command_name, *subcommands = args
          case command = Command.parse?(command_name)
          in Nil
            STDERR.puts "Unknown command: #{command_name}"
            if possible_name = Levenshtein.find(command_name, Command.values.map(&.to_s.downcase))
              STDERR.puts "Did you mean `#{possible_name}`?"
            end
            exit 1
          in .generate?, .g?
            Commands::Generate.call subcommands
          end
        end

        parser.invalid_option do |flag|
          # Do nothing because it'll be handled by nested commands
        end
      end
    end
  end
end

Wax::CLI.call
