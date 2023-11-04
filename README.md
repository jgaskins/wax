# wax

Wax is an opinionated Crystal code generator for web applications and APIs. It
provides conventions to follow to write your backend Crystal code more quickly
using a few different Crystal shards:

- [Armature](https://github.com/jgaskins/armature) for HTTP routing
- [Interro](https://github.com/jgaskins/interro) for querying your Postgres database
- [Mosquito](https://github.com/mosquito-cr/mosquito) for background jobs
- [Redis](https://github.com/jgaskins/redis) as the backing store for caching, background jobs, and sessions
- [Dotenv](https://github.com/gdotdesign/cr-dotenv) for loading configuration from .env files

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     wax:
       github: jgaskins/wax
   ```

2. Run `shards install` to install `wax` and its dependencies

## Usage

From your terminal:

```bash
bin/wax generate app YourAppName
```

Wax will generate all the files your app needs to get started for your app. You can also abbreviate `generate` as `g`:

```bash
bin/wax g app YourAppName
```

### Generating 

You can generate several kinds of files:

| Files | Command |
|-------|---------|
| App   | `bin/wax g app OnlineStore` |
| Models | `bin/wax g model Product id:uuid:pkey title:string description:string` |
| Migration | `bin/wax g migration add column products active:boolean` |
| Routes | `bin/wax g route Catalog` |
| Components | `bin/wax g component DatePicker` |

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/jgaskins/wax/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
