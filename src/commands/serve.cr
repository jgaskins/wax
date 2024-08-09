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
      name
      Dir.mkdir_p "public"
      compile_js = "npx rollup assets/app.js -c"
      system compile_js

      spawn web.run
      spawn worker.run
      spawn css.run

      begin
        spawn @javascript = Process.new("#{compile_js} --watch", shell: true)
        # spawn @css = Process.new("#{compile_css} --watch", shell: true)

        sleep
      ensure
        javascript.wait
      end
    end

    getter web : Sentry::ProcessRunner do
      Sentry::ProcessRunner.new(
        display_name: "#{name} web",
        build_command: "time GC_DONT_GC=1 shards build #{name}-web --error-trace",
        run_command: "bin/#{name}-web",
        files: ["src/**/*.cr", "views/**/*.ecr"],
      )
    end

    getter worker : Sentry::ProcessRunner do
      Sentry::ProcessRunner.new(
        display_name: "#{name} worker",
        build_command: "time GC_DONT_GC=1 shards build #{name}-worker --error-trace",
        run_command: "bin/#{name}-worker",
        files: ["src/**/*.cr", "views/**/*.ecr"],
      )
    end

    getter! javascript : Process

    getter css : Sentry::ProcessRunner do
      Sentry::ProcessRunner.new(
        display_name: "#{name} CSS builder",
        build_command: "node_modules/.bin/tailwindcss -i assets/app.css -o public/app.css --minify",
        run_command: "true",
        files: %w[
          src/**/*.cr
          views/**/*.ecr
          assets/**/*.css
        ],
      )
    end
  end
end
