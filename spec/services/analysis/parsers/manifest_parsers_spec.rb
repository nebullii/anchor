require "rails_helper"

RSpec.describe "Analysis manifest parsers" do
  describe Analysis::Parsers::GemfileLock do
    let(:lock) do
      <<~LOCK
        GIT
          remote: https://github.com/example/private_gem.git
          revision: abc
          specs:
            private_gem (0.1.0)

        GEM
          remote: https://rubygems.org/
          specs:
            nokogiri (1.16.4-x86_64-linux)
              racc (~> 1.4)
            rails (7.1.3)
              railties (= 7.1.3)
            railties (7.1.3)

        PLATFORMS
          x86_64-linux

        DEPENDENCIES
          private_gem!
          rails (~> 7.1)

        RUBY VERSION
           ruby 3.3.0p0

        BUNDLED WITH
           2.5.6
      LOCK
    end

    subject(:parsed) { described_class.parse(lock) }

    it "reads resolved specs with versions, platforms and line numbers" do
      expect(parsed.version_of("rails")).to eq("7.1.3")
      expect(parsed.specs["nokogiri"]).to have_attributes(version: "1.16.4", platform: "x86_64-linux")
      expect(parsed.gem?("private_gem")).to be true
      expect(parsed.line_of("rails")).to eq(lock.lines.index { |l| l.include?("rails (7.1.3)") } + 1)
    end

    it "does not treat nested dependency lines as specs" do
      expect(parsed.gem?("racc")).to be false
    end

    it "reads dependencies, platforms, ruby and bundler versions" do
      expect(parsed.dependencies).to eq(%w[private_gem rails])
      expect(parsed.platforms).to eq([ "x86_64-linux" ])
      expect(parsed.ruby_version).to eq("3.3.0")
      expect(parsed.bundler_version).to eq("2.5.6")
    end

    it "rejects merge conflict markers and unknown sections" do
      expect { described_class.parse("GEM\n<<<<<<< HEAD\n") }.to raise_error(Analysis::Parsers::ParseError, /merge conflict/)
      expect { described_class.parse("NONSENSE\n  foo\n") }.to raise_error(Analysis::Parsers::ParseError)
    end

    it "accepts an empty file" do
      expect(described_class.parse("").specs).to eq({})
    end
  end

  describe Analysis::Parsers::Gemfile do
    it "reads gems, groups and the ruby directive without evaluating code" do
      parsed = described_class.parse(<<~RUBY)
        source "https://rubygems.org"
        ruby "3.3.1"
        gem "rails", "~> 8.0" # comment
        gem 'pg'
        platforms :ruby do
          gem "sqlite3"
        end
        group :development, :test do
          gem "rspec-rails"
        end
        gem "rubocop", group: :development
        system("rm -rf /") # never executed
      RUBY

      expect(parsed.gems.map(&:name)).to eq(%w[rails pg sqlite3 rspec-rails rubocop])
      expect(parsed.find("rails")).to have_attributes(requirement: "~> 8.0", line: 3)
      expect(parsed.find("rspec-rails").groups).to eq(%w[development test])
      expect(parsed.find("rubocop").groups).to eq(%w[development])
      expect(parsed.find("pg").groups).to eq([])
      expect(parsed.ruby_requirement).to eq("3.3.1")
    end

    it "does not mistake rails-adjacent gems for rails" do
      parsed = described_class.parse(%(gem "rails-html-sanitizer"\ngem "sprockets-rails"\n))
      expect(parsed.gem?("rails")).to be false
    end

    it "reads ruby file: directives" do
      expect(described_class.parse(%(ruby file: ".ruby-version")).ruby_file).to eq(".ruby-version")
    end
  end

  describe Analysis::Parsers::Requirements do
    it "handles comments, options, extras, markers, continuations and URLs" do
      reqs = described_class.parse(<<~REQ)
        # comment
        -r base.txt
        --index-url https://example.com/simple
        Flask_SQLAlchemy==3.1 # inline
        uvicorn[standard]>=0.30 ; python_version >= "3.9"
        gunicorn==23.0.0 \\
            --hash=sha256:abc
        -e git+https://github.com/x/y.git#egg=y
        mypkg @ https://example.com/mypkg.whl
        ./local/package
      REQ

      expect(reqs.map(&:name)).to eq(%w[flask-sqlalchemy uvicorn gunicorn mypkg])
      expect(reqs.first.specifier).to eq("==3.1")
      expect(reqs.map(&:line)).to eq([ 4, 5, 6, 9 ])
    end

    it "normalises names per PEP 503" do
      expect(described_class.normalize("Django_REST.framework")).to eq("django-rest-framework")
    end
  end

  describe Analysis::Parsers::GoMod do
    it "reads module, go, toolchain and requirements" do
      mod = described_class.parse(<<~MOD)
        module github.com/acme/api // the api

        go 1.22.3

        toolchain go1.23.1

        require github.com/google/uuid v1.6.0

        require (
        	github.com/go-chi/chi/v5 v5.0.12
        	golang.org/x/sync v0.7.0 // indirect
        )

        replace (
        	example.com/a => ../a
        )
      MOD

      expect(mod.module_path).to eq("github.com/acme/api")
      expect(mod.go_version).to eq("1.22.3")
      expect(mod.go_minor).to eq("1.22")
      expect(mod.go_line).to eq(3)
      expect(mod.toolchain).to eq("1.23.1")
      expect(mod.requires.map(&:path)).to eq(%w[github.com/google/uuid github.com/go-chi/chi/v5 golang.org/x/sync])
    end

    it "raises on invalid directives" do
      expect { described_class.parse("module x\ngo banana\n") }.to raise_error(Analysis::Parsers::ParseError, /go directive/)
      expect { described_class.parse("modul x\n") }.to raise_error(Analysis::Parsers::ParseError)
      expect { described_class.parse("go 1.21\n") }.to raise_error(Analysis::Parsers::ParseError, /module/)
    end
  end

  describe Analysis::Parsers::MixExs do
    it "reads app name, elixir requirement and deps" do
      mix = described_class.parse(<<~EX)
        defmodule Demo.MixProject do
          def project, do: [app: :demo, elixir: "~> 1.15", deps: deps()]
          defp deps do
            [
              {:phoenix, "~> 1.7"},
              {:jason, ">= 0.0.0"},
              {:local_dep, path: "../dep"}
            ]
          end
        end
      EX

      expect(mix.app_name).to eq("demo")
      expect(mix.elixir_requirement).to eq("~> 1.15")
      expect(mix.deps.map(&:name)).to eq(%w[phoenix jason local_dep])
      expect(mix.line_of("phoenix")).to eq(5)
    end

    it "raises when there is no module" do
      expect { described_class.parse("IO.puts :hi") }.to raise_error(Analysis::Parsers::ParseError)
    end
  end

  describe Analysis::Parsers::PackageJson do
    it "exposes dependencies, scripts, engines, packageManager and workspaces" do
      pkg = described_class.parse(<<~JSON)
        {
          "name": "x",
          "packageManager": "pnpm@9.1.0+sha512.abc",
          "engines": { "node": ">=20" },
          "workspaces": { "packages": ["apps/*"] },
          "scripts": { "start": "node server.js", "build": "  " },
          "dependencies": { "express": "^4" },
          "devDependencies": { "typescript": "^5" }
        }
      JSON

      expect(pkg.dependency?("typescript")).to be true
      expect(pkg.script("start")).to eq("node server.js")
      expect(pkg.script("build")).to be_nil
      expect(pkg.engines_node).to eq(">=20")
      expect(pkg.package_manager).to eq(%w[pnpm 9.1.0])
      expect(pkg.workspaces).to eq([ "apps/*" ])
      expect(pkg.line_for_dependency("express")).to eq(7)
    end

    it "raises ParseError on invalid JSON or non-objects" do
      expect { described_class.parse("{") }.to raise_error(Analysis::Parsers::ParseError)
      expect { described_class.parse("[]") }.to raise_error(Analysis::Parsers::ParseError)
    end
  end

  describe Analysis::Parsers::Dockerfile do
    it "reads instructions across continuations and finds final-stage EXPOSE/USER" do
      df = described_class.parse(<<~DOCKER)
        FROM node:22 AS build
        EXPOSE 1234
        USER builder

        FROM node:22-alpine
        # comment
        RUN apk add \\
          # inline comment
          curl
        EXPOSE 8080/tcp 9090
        USER node:node
      DOCKER

      expect(df.exposed_ports).to eq([ [ 8080, 10 ], [ 9090, 10 ] ])
      expect(df.final_user).to eq("node:node")
      expect(df.all("RUN").first.args).to include("curl")
    end
  end

  describe Analysis::RuntimeVersions do
    it "cleans version files" do
      expect(described_class.clean("v20.11.1\n")).to eq("20.11.1")
      expect(described_class.clean("ruby-3.3.0")).to eq("3.3.0")
      expect(described_class.clean("python-3.11.4")).to eq("3.11.4")
      expect(described_class.clean("lts/*")).to be_nil
    end

    it "resolves npm engine ranges to a Node line" do
      expect(described_class.node_line_for(">=18")).to eq("22")
      expect(described_class.node_line_for("^20.9.0")).to eq("20")
      expect(described_class.node_line_for("18.x")).to eq("18")
      expect(described_class.node_line_for(">=18 <21")).to eq("20")
      expect(described_class.node_line_for("16 || 18")).to eq("18")
      expect(described_class.node_line_for("18 - 20")).to eq("20")
      expect(described_class.node_line_for("~16.14")).to eq("16")
    end

    it "resolves Python specifiers to a Python line" do
      expect(described_class.python_line_for(">=3.11")).to eq("3.12")
      expect(described_class.python_line_for(">=3.9,<3.12")).to eq("3.11")
      expect(described_class.python_line_for("~=3.10")).to eq("3.12")
      expect(described_class.python_line_for("==3.10.*")).to eq("3.10")
      expect(described_class.python_line_for("^3.13")).to eq("3.13")
      expect(described_class.python_line_for("3.11")).to eq("3.11")
    end

    it "resolves Elixir requirements to a line with verified images" do
      expect(described_class.elixir_line_for("~> 1.15")).to eq("1.18")
      expect(described_class.elixir_line_for("~> 1.16.2")).to eq("1.16")
      expect(described_class.elixir_line_for(nil)).to eq(described_class::DEFAULTS["elixir"])
    end
  end
end
