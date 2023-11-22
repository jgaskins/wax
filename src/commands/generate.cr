require "../generators/**"

module Wax::Commands
  module Generate
    extend self

    alias Generator = Generators::Generator

    def call(args : Array(String))
      if (type = args.first?)
        type, *args = args
        Generator
          .for(type)
          .new(args)
          .call
      else
        STDERR.puts "What do you want to generate?"
        STDERR.puts
        size = Generator::SUBCOMMANDS.keys.max_by(&.to_s.size).to_s.size
        Generator::SUBCOMMANDS.each do |name, generator_class|
          STDERR.puts "#{name.to_s.downcase.ljust size, ' '} - #{generator_class.description}"
        end
        exit 1
      end
    end
  end
end
