require "rails_helper"

RSpec.describe Analysis::Preflight do
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  def write(path, content)
    full = File.join(repo_path, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def findings(secret_keys: [])
    detection = FrameworkDetector.new(repo_path, nil).call
    described_class.new(repo_path, detection, secret_keys: secret_keys).call
  end

  def ids(list = findings)
    list.map { |f| f[:id] }
  end

  it "returns the contract shape, sorted by severity" do
    write("package.json", %({"scripts":{"dev":"x"},"dependencies":{"express":"^4"}}))
    write("server.js", %(require("express")().listen(4000, "localhost")))

    list = findings
    expect(list).to all(match(id: String, severity: a_string_matching(/\A(error|warning|info)\z/),
                              message: String, file: anything, line: anything, fix: String))
    expect(list.map { |f| described_class::SEVERITY_ORDER[f[:severity]] }).to eq(list.map { |f| described_class::SEVERITY_ORDER[f[:severity]] }.sort)
  end

  it "documents every rule it can emit" do
    source = File.read(Rails.root.join("app/services/analysis/preflight.rb"))
    emitted = source.scan(/add\("([a-z_]+)"/).flatten.uniq
    expect(described_class::RULES.keys).to include(*emitted)
  end

  describe "networking" do
    it "is quiet when a node server reads $PORT and binds all interfaces" do
      write("package.json", %({"scripts":{"start":"node server.js"},"dependencies":{"express":"^4"}}))
      write("server.js", %(const app = require("express")();\napp.listen(process.env.PORT || 3000);\n))

      expect(ids).not_to include("bind_localhost", "port_mismatch", "port_not_from_env")
    end

    it "warns (not errors) when a hard-coded port matches the container port" do
      write("package.json", %({"scripts":{"start":"node server.js"},"dependencies":{"express":"^4"}}))
      write("server.js", %(require("express")().listen(3000);\n))

      finding = findings.find { |f| f[:id] == "port_not_from_env" }
      expect(finding).to include(severity: "warning", file: "server.js", line: 1)
    end

    it "flags Go servers bound to localhost" do
      write("go.mod", "module x\n\ngo 1.25\n")
      write("main.go", %(package main\n\nfunc main() {\n\thttp.ListenAndServe("127.0.0.1:8080", nil)\n}\n))

      expect(findings.find { |f| f[:id] == "bind_localhost" }).to include(file: "main.go", line: 4)
    end

    it "flags Phoenix endpoints bound to 127.0.0.1 in production config" do
      write("mix.exs", %(defmodule X.MixProject do\n  def project, do: [app: :x]\n  defp deps, do: [{:phoenix, "~> 1.7"}]\nend\n))
      write("config/runtime.exs", "config :x, XWeb.Endpoint,\n  http: [ip: {127, 0, 0, 1}, port: 4000]\n")

      expect(findings.find { |f| f[:id] == "bind_localhost" }).to include(file: "config/runtime.exs", line: 2)
    end

    it "ignores app.run() for Flask apps served by gunicorn" do
      write("requirements.txt", "flask\ngunicorn\n")
      write("app.py", %(app = Flask(__name__)\nif __name__ == "__main__":\n    app.run(host="127.0.0.1", port=5001)\n))

      expect(ids).not_to include("bind_localhost", "port_mismatch")
    end
  end

  describe "secrets and env files" do
    it "errors on committed .env files with secret values and names the line" do
      write("package.json", %({"scripts":{"start":"node i.js"}}))
      write("i.js", "")
      write(".env", "NODE_ENV=production\nSTRIPE_SECRET_KEY=sk_live_fixture_value\n")
      write(".env.example", "STRIPE_SECRET_KEY=sk_live_fixture_value\n")

      finding = findings.find { |f| f[:id] == "committed_secrets" }
      expect(finding).to include(severity: "error", file: ".env", line: 2)
      expect(findings.map { |f| f[:file] }).not_to include(".env.example")
    end

    it "only warns for .env files without secret values" do
      write("index.html", "<h1>hi</h1>")
      write(".env.local", "API_TOKEN=\nTHEME=dark\n")

      expect(findings.find { |f| f[:file] == ".env.local" }).to include(id: "committed_env_file", severity: "warning")
    end

    it "errors when the Rails master key is committed" do
      write("Gemfile", %(gem "rails"\n))
      write("config/master.key", "0123456789abcdef0123456789abcdef")

      expect(findings.find { |f| f[:id] == "rails_master_key_committed" }).to include(severity: "error", file: "config/master.key")
    end

    it "suppresses env_var_not_set and secret key findings once the secrets exist" do
      write("Gemfile", %(gem "rails"\ngem "pg"\n))
      write("config/initializers/x.rb", %(ENV.fetch("PAYMENTS_TOKEN")\nENV.fetch("OPTIONAL", nil)\n))

      before = ids(findings(secret_keys: []))
      after  = ids(findings(secret_keys: %w[PAYMENTS_TOKEN DATABASE_URL SECRET_KEY_BASE]))

      expect(before).to include("env_var_not_set", "rails_secret_key_base_missing")
      expect(findings(secret_keys: []).select { |f| f[:id] == "env_var_not_set" }.map { |f| f[:message][/\A\w+/] })
        .to contain_exactly("PAYMENTS_TOKEN", "DATABASE_URL")
      expect(after).not_to include("env_var_not_set", "rails_secret_key_base_missing")
    end

    it "skips secret checks entirely when the project's secrets are unknown" do
      write("Gemfile", %(gem "rails"\n))
      detection = FrameworkDetector.new(repo_path, nil).call
      list = described_class.new(repo_path, detection).call

      expect(ids(list)).not_to include("env_var_not_set", "rails_secret_key_base_missing")
    end

    it "ignores env access in specs and development config" do
      write("Gemfile", %(gem "rails"\n))
      write("spec/support/x.rb", %(ENV.fetch("TEST_ONLY_KEY")\n))
      write("config/environments/development.rb", %(ENV.fetch("DEV_ONLY_KEY")\n))

      expect(findings.map { |f| f[:message] }.join).not_to include("TEST_ONLY_KEY", "DEV_ONLY_KEY")
    end
  end

  describe "repository hygiene" do
    it "warns about very large files" do
      write("index.html", "<h1>hi</h1>")
      File.open(File.join(repo_path, "data.bin"), "wb") { |f| f.truncate(described_class::LARGE_FILE_BYTES + 1) }

      expect(findings.find { |f| f[:id] == "large_file" }).to include(file: "data.bin", severity: "warning")
    end

    it "warns about committed node_modules" do
      write("package.json", %({"scripts":{"start":"node i.js"}}))
      write("i.js", "")
      write("node_modules/left-pad/index.js", "")

      expect(ids).to include("committed_dependencies")
    end
  end

  describe "Dockerfiles" do
    it "flags EXPOSE mismatches when the configured port differs" do
      write("Dockerfile", "FROM scratch\nEXPOSE 9000\nUSER app\n")
      detection = FrameworkDetector::Result.new(framework: "docker", runtime: "custom", port: 8080, metadata: {})

      list = described_class.new(repo_path, detection).call
      expect(list.find { |f| f[:id] == "dockerfile_expose_mismatch" }).to include(file: "Dockerfile", line: 2)
    end

    it "notes Dockerfiles without EXPOSE or USER" do
      write("Dockerfile", "FROM scratch\nCMD [\"/app\"]\n")

      expect(ids).to include("dockerfile_no_expose", "dockerfile_runs_as_root")
    end
  end

  describe "runtime versions" do
    it "flags unrecognised version files" do
      write("package.json", %({"scripts":{"start":"node i.js"}}))
      write("i.js", "")
      write(".nvmrc", "hydrogen-ish\n")

      expect(findings.find { |f| f[:id] == "runtime_version_unrecognized" }).to include(file: ".nvmrc", severity: "info")
    end

    it "accepts lts aliases" do
      write("package.json", %({"scripts":{"start":"node i.js"}}))
      write("i.js", "")
      write(".nvmrc", "lts/*\n")

      expect(ids).not_to include("runtime_version_unrecognized")
    end

    it "warns about end-of-life Python" do
      write("requirements.txt", "requests\n")
      write("main.py", "print(1)\n")
      write(".python-version", "3.9.18\n")

      expect(findings.find { |f| f[:id] == "runtime_version_eol" }).to include(file: ".python-version")
    end
  end

  describe "nothing to deploy" do
    it "errors when no app is found" do
      write("README.md", "# hi")
      expect(findings.find { |f| f[:id] == "no_app_detected" }).to include(severity: "error")
    end
  end

  describe "robustness" do
    it "keeps going when a rule raises" do
      write("index.html", "<h1>hi</h1>")
      detection = FrameworkDetector.new(repo_path, nil).call
      preflight = described_class.new(repo_path, detection, secret_keys: [])
      allow(preflight).to receive(:check_large_files).and_raise("boom")

      expect { preflight.call }.not_to raise_error
    end

    it "tolerates a nil detection" do
      write("index.html", "<h1>hi</h1>")
      expect { described_class.new(repo_path, nil).call }.not_to raise_error
    end

    it "handles binary and invalid UTF-8 source files" do
      write("package.json", %({"scripts":{"start":"node i.js"}}))
      File.binwrite(File.join(repo_path, "i.js"), "\xFF\xFE listen(\x00".b)

      expect { findings }.not_to raise_error
    end
  end
end
