require "sentry"
require "yaml"

module Wax::Commands
  class Serve
    getter name : String do
      if File.exists?("shard.yml")
        if name = YAML.parse(File.read("shard.yml"))["name"]?.try(&.as_s?)
          name
        else
          "app"
        end
      else
        raise ArgumentError.new("Please run `bin/wax serve` from your app's root directory and make there is a shard.yml file")
      end
    end

    def self.call(args : Array(String))
      new.call args
    end

    def call(args : Array(String))
      spawn web.run
      spawn worker.run

      spawn system "npx rollup assets/app.js -c --watch"
      spawn system "npx tailwindcss -i assets/app.css -o public/app.css --watch --minify"

      sleep
    end

    getter web : Sentry::ProcessRunner do
      Sentry::ProcessRunner.new(
        display_name: "#{name} web",
        build_command: "time GC_DONT_GC=1 shards build #{name}-web --error-trace ",
        run_command: "bin/#{name}-web",
        files: ["src/**/*.cr", "views/**/*.ecr"],
      )
    end

    getter worker : Sentry::ProcessRunner do
      Sentry::ProcessRunner.new(
        display_name: "#{name} worker",
        build_command: "time GC_DONT_GC=1 shards build #{name}-worker",
        run_command: "bin/#{name}-worker",
        files: ["src/**/*.cr", "views/**/*.ecr"],
      )
    end

    getter! javascript : Process
    getter! css : Process
  end
end
