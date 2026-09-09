# frozen_string_literal: true

require_relative "lib/rakpak/version"

Gem::Specification.new do |spec|
  spec.name = "rakpak"
  spec.version = Rakpak::VERSION
  spec.authors = ["Ryan Wilson"]
  spec.email = ["ryan@ryanwilson.io"]

  spec.summary = "Tag files anywhere on your filesystem, archive them all at once, and unpack again, " \
                 "from the terminal."
  spec.description = "A terminal file browser for building archives. Walk around, tag files and " \
                     "folders wherever they live, then pack them into one compressed tarball, plain " \
                     "tarball or zip. Unpacks them again too, from the browser or straight from the " \
                     "command line. No dependencies beyond Ruby and the archive tools on your machine."
  spec.homepage = "https://github.com/eof0/rakpak"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "bin/rakpak", "README.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["rakpak"]
  spec.require_paths = ["lib"]
end
