require "yaml"

module Wax
  class_getter config : Config do
    File.open ".wax/config.yml" do |file|
      Config.from_yaml file
    end
  rescue ex : File::NotFoundError
    Config.new
  end

  abstract struct Property
    include YAML::Serializable

    macro inherited
      def initialize
      end
    end
  end

  struct Config < Property
    getter ai : AI = AI.new

    # ai:
    #   context:
    #     exclude:
    #     - src/tools

    struct AI < Property
      getter context : Context = Context.new
    end

    struct Context < Property
      getter exclude : Array(String) = %w[]
    end
  end

  module Commands::Config
    extend self

    def call(args : Array(String))
      if args.empty?
        STDERR.puts "Must supply a prompt"
        exit 1
      end

      OptionParser.parse args.dup do |parser|
        parser.on "show", "Shows the current configuration in `.wax/config.yml`" do
          pp Wax.config
        end
      end
    end
  end
end
