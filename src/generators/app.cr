require "./generator"
require "http"
require "yaml"

module Wax::Generators
  class App < Generator
    handle "app"

    getter name : String

    def self.description
      "Generates a complete application scaffold"
    end

    def self.new(args : Array(String))
      new args.first
    end

    def initialize(@name)
    end

    def call
      config
      queries
      models
      routes
      web
      views
      assets
      jobs
      specs
      dockerfile

      puts <<-EOF

        Done writing app files. You can add the following to your shard.yml
        under `targets` to get `shards build` functionality:

        Run `bin/setup` to install dependencies and create the DB.
        Run `bin/wax serve` to start the web app, background-job worker, and asset compiler

        EOF
    end

    def config
      file "src/config/config.cr", <<-EOF
        module Config
          macro define(name, &block)
            module ::Config
              class_getter {{name}} do
                {{yield}}
              end
            end
          end
        end

        EOF

      file ".gitignore", <<-EOF
        /docs/
        /lib/
        /bin/
        /.shards/
        *.dwarf
        .env
        node_modules
        /public/app*.js
        /public/app*.css

        EOF

      env
      cache
      db
      sessions
      log
      bin
    end

    def env
      file "src/config/env.cr", <<-EOF
        require "wax/load"
        require "dotenv"
        Dotenv.load?

        EOF

      file ".env", <<-EOF
        DATABASE_URL="postgres:///#{@name.underscore}_dev?max_idle_pool_size=25"
        REDIS_URL="redis:///"
        HOST=127.0.0.1
        PORT=3200
        ASSET_CACHE_DURATION_SECONDS=0

        EOF

      file ".env.test", <<-EOF
        DATABASE_URL="postgres:///#{@name.underscore}_test"
        LOG_LEVEL=warn

        EOF
    end

    def cache
      file "src/config/cache.cr", <<-EOF
        require "armature/cache"
        require "armature/cache/redis"
        require "./config"
        require "./redis"

        Armature.cache = Armature::Cache::RedisStore.new(Config.redis)

        EOF
    end

    def db
      file "src/config/db.cr", <<-EOF
        require "./env"
        require "interro"

        Interro.config do |c|
          db = DB.open(ENV["DATABASE_URL"])
          c.write_db = db

          if replica_db_url = ENV["DATABASE_REPLICA_URL"]?
            replica_db = DB.open(replica_db_url)
            c.read_db = replica_db
          else
            c.read_db = db
          end

          [
            db,
            replica_db,
          ].compact.each &.setup_connection do |c|
            c.exec "SET statement_timeout = #{ENV.fetch("SQL_STATEMENT_TIMEOUT_MS", "10000")}"
          end
        end

        EOF
    end

    def sessions
      redis
      file "src/config/sessions.cr", <<-EOF
        require "armature/redis_session"

        require "./config"
        require "./redis"

        Config.define sessions : Armature::Session::RedisStore do
          Armature::Session::RedisStore.new(
            key: "#{@name.tr(" ", "_")}_session",
            redis: Config.redis,
            expiration: 365.days, # 1 year
          )
        end

        EOF
    end

    def redis
      file "src/config/redis.cr", <<-EOF
        require "redis"

        require "./config"
        require "./env"

        Config.define redis : Redis::Client do
          Redis::Client.from_env("REDIS_URL")
        end

        EOF
    end

    def log
      file "src/config/log.cr", <<-EOF
        require "log"

        require "./env"

        Log.setup_from_env

        EOF
    end

    def bin
      file "bin/setup", <<-EOF, executable: true
        #!/usr/bin/env bash

        createdb #{name.underscore}_dev
        createdb #{name.underscore}_test
        bin/interro-migration run
        spec/prepare_db.sh

        npm install --global npx > /dev/null 2>&1
        npm install

        EOF

      file "bin/dev", <<-EOF, executable: true
        #!/usr/bin/env bash

        bin/setup
        bin/wax serve
        EOF

      shard = ShardConfig.from_yaml(File.read("shard.yml"))
      shard.targets["#{name.underscore}-web"] = ShardConfig::Target.new("src/web.cr")
      shard.targets["#{name.underscore}-worker"] = ShardConfig::Target.new("src/worker.cr")
      File.write "shard.yml", shard.to_yaml
    end

    struct ShardConfig
      include YAML::Serializable
      include YAML::Serializable::Unmapped

      getter name : String
      getter version : String
      getter authors : Array(String)
      getter targets : Hash(String, Target) { {} of String => Target }
      getter dependencies : Hash(String, Dependency) { {} of String => Dependency }
      getter development_dependencies : Hash(String, Dependency) { {} of String => Dependency }
      getter crystal : String
      getter license : String?

      struct Target
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        getter main : String

        def initialize(@main)
        end
      end

      struct Dependency
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        getter path : String?
        getter github : String?
        getter branch : String?
        getter commit : String?
      end
    end

    def queries
      file "src/queries/query.cr", <<-EOF
        require "wax/load"
        src "config/db"

        abstract struct Query(T) < Interro::QueryBuilder(T)
          include Interro::Validations
        end

        EOF

      file "src/queries/user.cr", <<-EOF
        require "./query"

        src "models/user"

        struct UserQuery < Query(User)
          table "users"

          def find(id : UUID)
            where(id: id).first?
          end

          def find_by(*, email : String)
            where(email: email).first?
          end

          def with_role(role : User::Role)
            where role: role.value
          end

          def create(email : String, name : String, password : BCrypt::Password, role : User::Role = :member)
            Result(User).new
              .validate_presence(email: email, name: name)
              .validate_uniqueness("email") { where(email: email).any? }
              .validate("role must be a valid user role") { User::Role.valid? role }
              .valid do
                insert email: email, name: name, password: password.to_s, role: role.value
              end
          end
        end

        EOF
    end

    def query(model, table)
      file "src/queries/#{model.underscore}.cr", <<-EOF
        require "./query"

        src "models/#{model.underscore}"

        struct #{model}Query < Query(#{model})
          table "#{table}"
        end

        EOF
    end

    def models
      file "src/models/model.cr", <<-EOF
        require "db"
        require "uuid"
        require "msgpack"

        abstract struct Model
          include DB::Serializable
          include MessagePack::Serializable
        end

        struct UUID
          def self.new(unpacker : MessagePack::Unpacker)
            new unpacker.read_bytes
          end

          def to_msgpack(packer : MessagePack::Packer)
            packer.write bytes.to_slice
          end
        end

        EOF

      file "src/models/user.cr", <<-EOF
        require "./model"

        src "bcrypt"

        struct User < Model
          getter id : UUID
          getter email : String
          getter name : String
          @[DB::Field(converter: BCrypt::Password)]
          getter password : BCrypt::Password
          getter role : Role
          getter created_at : Time
          getter updated_at : Time

          enum Role
            Member = 0
            Admin  = 1
          end
        end

        EOF

      now = Time.utc
      time_string = "%04d_%02d_%02d_%02d_%02d_%02d_%09d" % [
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
        now.nanosecond,
      ]
      file "db/migrations/#{time_string}-CreateUsers/up.sql", <<-EOF
        CREATE TABLE users(
          id UUID PRIMARY KEY NOT NULL DEFAULT gen_random_uuid(),
          email TEXT UNIQUE NOT NULL,
          name TEXT NOT NULL,
          password TEXT NOT NULL,
          role INT4 NOT NULL DEFAULT 0,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )

        EOF
      file "db/migrations/#{time_string}-CreateUsers/down.sql", <<-EOF
        DROP TABLE users

        EOF
    end

    def routes
      file "src/routes/route.cr", <<-EOF
        require "armature/route"
        require "armature/form"
        require "wax/load"

        src "config/cache"

        module Route
          include Armature::Route
          include Armature::Form::Helper
          include Armature::Cache

          # Add helper methods here
        end

        EOF

      file "spec/routes/route_helper.cr", <<-EOF
        require "wax-spec/route_helper"
        require "../spec_helper"

        EOF
    end

    def web
      file "src/web.cr", <<-EOF
        require "http"
        require "wax/load"

        src "config/env"
        src "config/log"
        src "config/sessions"
        src "routes/web"

        log = Log.for("#{@name.underscore}.web")
        http = HTTP::Server.new([
          HTTP::LogHandler.new(log),
          HTTP::CompressHandler.new,
          HTTP::StaticFileHandler.new("public", directory_listing: false),
          Config.sessions,
          Web.new,
        ])

        # Shut down gracefully
        [
          Signal::INT,
          Signal::TERM,
        ].each(&.trap { http.close })

        host = ENV.fetch("HOST", "0.0.0.0")
        port = ENV.fetch("PORT", "3200").to_i
        log.info &.emit "Listening for HTTP requests", host: host, port: port
        http.listen host, port

        EOF

      file "src/routes/web.cr", <<-EOF
        require "./route"
        require "wax/assets"

        src "queries/user"
        src "routes/home"
        src "routes/login"
        src "routes/signup"

        class Web
          include Route
          include HTTP::Handler

          def call(context)
            route context do |r, response, session|
              current_user = authenticate(session)

              response.headers["content-type"] = "text/html"
              render "app/header"

              r.root { Home.new.call context }

              r.on "signup" { Signup.new.call context }
              r.on "login" { Login.new.call context }

              if current_user
                # Authenticated-only routes go here
              end

              # Add publicly available routes here

              r.miss do
                response.status = :not_found
                render "app/not_found"
              end

              render "app/footer"
            end
          end

          def authenticate(session)
            if (current_user_id = session["user_id"]?.try(&.as_s?)) && (current_user_id = UUID.parse?(current_user_id))
              UserQuery.new.find(current_user_id)
            end
          end

          getter assets : Wax::Assets { Wax::Assets.new }
        end

        EOF

      file "src/routes/home.cr", <<-EOF
        require "./route"

        struct Home
          include Route

          def call(context)
            route context do |r, response, session|
              r.root { r.get { render "home/index" } }
            end
          end
        end

        EOF

      file "src/bcrypt.cr", <<-EOF
        require "crypto/bcrypt/password"

        alias BCrypt = Crypto::Bcrypt

        class BCrypt::Password
          def self.from_rs(rs : DB::ResultSet)
            new rs.read(String)
          end
        end

        EOF

      file "src/components/input.cr", <<-EOF
        require "armature/component"

        struct Input < Armature::Component
          getter name : String
          getter type : Type
          getter label : String
          getter id : String?
          @class : String?
          getter? autofocus : Bool
          getter? required : Bool

          def initialize(
            @name,
            @type = :text,
            @label = name.capitalize,
            @id = nil,
            @class = nil,
            @autofocus = false,
            @required = false
          )
          end

          def_to_s "components/input"

          def class_name
            @class
          end

          def attributes
            Attributes.new(
              name: name,
              type: type,
              id: id,
              class: @class,
              autofocus: autofocus?,
              required: required?,
            )
          end

          enum Type
            TEXT
            EMAIL
            PASSWORD
            HIDDEN
            DATETIME_LOCAL

            def to_s(io)
              to_s.each_char do |ch|
                case ch
                when '_'
                  io << '-'
                else
                  io << ch.downcase
                end
              end
            end
          end

          struct Attributes(T)
            def self.new(**attrs)
              new attrs
            end

            def initialize(@attrs : T)
            end

            def to_s(io) : Nil
              @attrs.each do |key, value|
                case value
                when nil, false
                  # Do nothing
                when true
                  io << ' ' << key.to_s
                else
                  io << ' ' << key << %{="}
                  HTML.escape value.to_s, io
                  io << '"'
                end
              end
            end
          end
        end

        EOF

      view "components/input", <<-EOF
        <div>
          <label>
            <%= @label %>
            <input<%== attributes %>>
          </label>
        </div>

        EOF

      file "src/routes/signup.cr", <<-EOF
        require "./route"
        require "../bcrypt"
        require "../components/input"

        struct Signup
          include Route

          def initialize(*, @password_cost = 12)
          end

          def call(context)
            route context do |r, response, session|
              r.root do
                r.get { render "signup/form" }
                r.post do
                  params = r.form_params
                  if valid_authenticity_token?(params, session)
                    email = params["email"]? || ""
                    name = params["name"]? || ""
                    password = params["password"]? || ""

                    case user = UserQuery.new.create(email: email, name: name, password: BCrypt::Password.create(password, cost: @password_cost))
                    in User
                      session["user_id"] = user.id.to_s
                      response.redirect "/"
                    in Interro::Validations::Failure
                      response.status = :unprocessable_entity
                      errors = user.errors
                      render "signup/errors"
                      render "signup/form"
                    end
                  else
                    response.status = :bad_request
                    response << "bad request"
                  end
                end
              end
            end
          end
        end

        EOF

      view "signup/errors", <<-EOF
        <style>
        #signup-errors {
          background: #fcc;
          color: red;
          border: 1px solid red;
          padding: 1em 1.25em;
          width: 800px;
          max-width: 100%;
          margin: 1em auto;
        }
        .signup-error {
        }
        </style>

        <ul id="signup-errors">
          <% errors.each do |error| %>
            <li class="signup-error">
              <%= error %>
            </li>
          <% end %>
        </ul>

        EOF

      view "signup/form", <<-EOF
        <div class="max-w-md mx-auto mt-8">
          <div class="bg-white dark:bg-gray-800 shadow-md rounded px-8 pt-6 pb-8 mb-4">
            <% form method: "POST", id: "signup-form", class: "space-y-6" do %>
              <div>
                <%== Input.new name: "email", type: :email, id: "email", class: "w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 dark:bg-gray-900 dark:text-white" %>
              </div>
              <div>
                <%== Input.new name: "name", id: "name", class: "w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 dark:bg-gray-900 dark:text-white" %>
              </div>
              <div>
                <%== Input.new name: "password", type: :password, id: "password", class: "w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 dark:bg-gray-900 dark:text-white" %>
              </div>
              <div>
                <button id="sign-up" class="w-full flex justify-center py-2 px-4 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500">
                  Sign up
                </button>
              </div>
            <% end %>
          </div>
        </div>

        EOF

      file "src/routes/login.cr", <<-EOF
        require "./route"
        require "../bcrypt"
        require "../components/input"

        struct Login
          include Route

          def call(context)
            route context do |r, response, session|
              r.root do
                r.get do
                  # Required variables for the form to be able to display login errors
                  # on POST.
                  error = nil
                  render "login/form"
                end

                r.post do
                  params = r.form_params
                  email = params["email"]?
                  password = params["password"]?

                  if email && password
                    if valid_authenticity_token?(params, session)
                      if (user = UserQuery.new.find_by(email: email)) && user.password.verify(password)
                        session["user_id"] = user.id.to_s
                        response.redirect "/"
                      else
                        response.status = :forbidden
                        error = "Invalid login"
                        render "login/form"
                      end
                    else
                      response.status = :bad_request
                      response << "bad request"
                    end
                  else
                    response.status = :bad_request
                    response << "Must supply login credentials"
                  end
                end
              end
            end
          end
        end

        EOF

      view "login/form", <<-EOF
        <div class="max-w-md mx-auto mt-8">
          <% if error %>
            <div class="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert">
              <strong class="font-bold">Error:</strong>
              <span class="block sm:inline"><%= error %></span>
            </div>
          <% end %>

          <div class="bg-white dark:bg-gray-800 shadow-md rounded px-8 pt-6 pb-8 mb-4">
            <% form method: "POST", class: "space-y-6" do %>
              <div>
                <%== Input.new name: "email", type: :email, class: "w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 dark:bg-gray-900 dark:text-white" %>
              </div>
              <div>
                <%== Input.new name: "password", type: :password, class: "w-full px-3 py-2 border border-gray-300 dark:border-gray-700 rounded-md focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 dark:bg-gray-900 dark:text-white" %>
              </div>
              <div>
                <button class="w-full flex justify-center py-2 px-4 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500">
                  Login
                </button>
              </div>
            <% end %>
          </div>
        </div>

        EOF
    end

    def views
      view "app/header", <<-EOF
        <!doctype html>
        <html class="dark bg-white dark:bg-gray-900">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <link rel="stylesheet" href="<%= assets["app.css"]? %>">
          <script src="<%= assets["app.js"]? %>"></script>
        </head>
        <body class="bg-white dark:bg-gray-900">
          <header class="bg-white dark:bg-gray-900">
            <div class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
              <h1 class="text-3xl font-bold leading-tight text-gray-900 dark:text-white">
                <a href="/">#{name.underscore.split('_').map(&.capitalize).join(' ')}</a>
              </h1>
              <nav class="mt-4">
                <% if current_user %>
                  <span class="text-gray-600 dark:text-gray-400">Logged in as <%= current_user.name %></span>
                <% else %>
                  <a href="/login" class="text-indigo-600 dark:text-indigo-400 hover:text-indigo-900 dark:hover:text-indigo-300">Login</a>
                  <span class="text-gray-600 dark:text-gray-400 mx-2">or</span>
                  <a href="/signup" class="text-indigo-600 dark:text-indigo-400 hover:text-indigo-900 dark:hover:text-indigo-300">sign up</a>
                <% end %>
              </nav>
            </div>
          </header>

          <main class="max-w-7xl mx-auto py-6 sm:px-6 lg:px-8 rounded-md bg-gray-100 dark:bg-gray-800 text-black dark:text-white">

        EOF
      view "app/footer", <<-EOF
          </main>

          <footer class="bg-white dark:bg-gray-900">
            <div class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
              <%# Footer content goes here %>
            </div>
          </footer>
        </body>
        </html>

        EOF

      view "home/index", <<-EOF
        <h2>Homepage</h2>

        EOF

      view "app/not_found", <<-EOF
        <h2>Not Found</h2>

        EOF
    end

    def view(path, template)
      file "views/#{path}.ecr", template
    end

    def assets
      file "package.json", <<-EOF
        {
          "devDependencies": {
            "@rollup/plugin-node-resolve": "^15.2.3",
            "@tailwindcss/forms": "^0.5.7",
            "autoprefixer": "^10.4.17",
            "postcss": "^8.4.33",
            "postcss-cli": "^11.0.0",
            "tailwindcss": "^3.4.1"
          },
          "dependencies": {
            "htmx.org": "^1.9.12"
          }
        }

        EOF

      file "tailwind.config.js", <<-EOF
        /** @type {import('tailwindcss').Config} */
        module.exports = {
          content: [
            "./src/**/*.cr",
            "./views/**/*.ecr",
          ],
          theme: {
            extend: {},
          },
          plugins: [
            require('@tailwindcss/forms'),
          ],
        }

        EOF

      file "postcss.config.js", <<-EOF
        module.exports = {
          plugins: {
            tailwindcss: {},
            autoprefixer: {},
          }
        }

        EOF

      file "rollup.config.mjs", <<-EOF
        import { nodeResolve } from '@rollup/plugin-node-resolve';

        export default {
          input: 'assets/app.js',
          output: {
            dir: 'public',
            format: 'cjs',
          },
          plugins: [nodeResolve()],
        };

        EOF

      file "assets/app.js", <<-EOF
        import "htmx.org"
        EOF
      file "assets/js/htmx.js", HTTP::Client.get("https://unpkg.com/htmx.org@1.9.10/dist/htmx.js").body

      file "assets/app.css", <<-EOF
        @tailwind base;
        @tailwind components;
        @tailwind utilities;
        EOF
    end

    def jobs
      file "src/config/conveyor.cr", <<-EOF
        require "conveyor"
        require "wax/load"

        require "./redis"

        Conveyor.configure do |c|
          c.redis = Config.redis
        end

        EOF

      file "src/worker.cr", <<-EOF
        require "./config/conveyor"
        require "./config/log"
        require "./jobs/**"

        [
          Signal::TERM,
          Signal::INT,
        ].each &.trap { Conveyor.orchestrator.stop }

        Log.for("conveyor").notice { "Starting" }
        Conveyor.orchestrator.start

        EOF

      file "src/jobs/job.cr", <<-EOF
        require "../config/conveyor"
        require "wax/load"

        abstract struct Job < Conveyor::Job
        end

        EOF

      file "src/jobs/example.cr", <<-EOF
        require "./job"

        struct ExampleJob < Job
          def initialize(@something : String)
          end

          def call
          end
        end

        EOF
    end

    def specs
      file "spec/spec_helper.cr", <<-EOF
        require "spec"
        require "wax/load"
        require "./config/env"

        EOF

      file "spec/config/env.cr", <<-EOF
        require "wax/load"
        require "dotenv"
        Dotenv.load? ".env.test"

        src "config/env"

        EOF

      file "spec/factories/factory.cr", <<-EOF
        require "wax-spec/factory"

        abstract struct Factory < Wax::Factory
        end

        EOF

      file "spec/prepare_db.sh", <<-EOF, executable: true
        #!/usr/bin/env bash

        set -e

        (
          source .env.test
          export DATABASE_URL
          createdb #{name.underscore}_test 2>&1 || true
          bin/interro-migration run
        )

        EOF
    end

    def dockerfile
      file "Dockerfile", <<-EOF
        FROM 84codes/crystal:1.14.0-alpine AS builder

        COPY shard.yml shard.lock /app/
        WORKDIR /app
        ENV SHARDS_OPTS="--static"
        RUN shards install --jobs 8 --production

        COPY src /app/src/
        COPY views /app/views/
        COPY db /app/db/
        RUN crystal build -o bin/web --static --release --stats --progress src/web.cr
        RUN crystal build -o bin/worker --static --release --stats --progress src/worker.cr

        # Deployable container
        FROM alpine

        RUN apk add --update --no-cache tzdata ca-certificates

        COPY --from=builder /app/bin/web /app/bin/worker /app/bin/interro-migration /app/bin/
        COPY --from=builder /app/db/ /app/db/
        WORKDIR /app

        CMD ["/app/bin/web"]

        EOF
    end
  end
end
