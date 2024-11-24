require "./spec_helper"
require "file_utils"
require "hot_topic"

src "assets"

describe Wax::Assets do
  public = Path["tmp/public"]

  # Make sure this stuff will work on a fresh deployment of a Wax app
  before_all do
    FileUtils.rm_rf public
    FileUtils.mkdir_p public
  end

  it "copies the contents of the file to a fingerprinted version of itself in the target directory" do
    assets = Wax::Assets.new(target: public.to_s)

    File.write (public / "foo.bar"), "asdf"

    assets["foo.bar"]?.should eq "/foo-#{Digest::SHA256.hexdigest("asdf")}.bar"
  end

  it "serves the content of the file" do
    content = "(function() {})()"
    File.write public / "example.js", content
    assets = Wax::Assets.new(target: public.to_s)
    app = HotTopic.new(assets)

    response = app.get "/example-#{Digest::SHA256.hexdigest(content)}.js"

    response.body.should eq content
  end
end
