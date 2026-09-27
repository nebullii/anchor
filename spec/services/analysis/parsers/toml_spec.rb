require "rails_helper"

RSpec.describe Analysis::Parsers::Toml do
  def parse(text)
    described_class.parse(text)
  end

  it "parses tables, dotted keys and scalar types" do
    doc = parse(<<~TOML)
      # comment
      title = "demo" # trailing comment
      [tool.poetry]
      name = 'literal'
      version = 3
      ratio = 1.5
      enabled = true
      released = 1979-05-27
      physical.color = "orange"
    TOML

    expect(doc["title"]).to eq("demo")
    expect(doc.dig("tool", "poetry")).to include(
      "name" => "literal", "version" => 3, "ratio" => 1.5, "enabled" => true, "released" => "1979-05-27"
    )
    expect(doc.dig("tool", "poetry", "physical", "color")).to eq("orange")
  end

  it "parses multi-line arrays with comments and trailing commas" do
    doc = parse(<<~TOML)
      [project]
      dependencies = [
          "fastapi>=0.115",  # web
          "uvicorn[standard]",
      ]
    TOML

    expect(doc.dig("project", "dependencies")).to eq([ "fastapi>=0.115", "uvicorn[standard]" ])
  end

  it "parses arrays of tables and inline tables (uv.lock shape)" do
    doc = parse(<<~TOML)
      version = 1
      [[package]]
      name = "fastapi"
      source = { registry = "https://pypi.org/simple" }
      dependencies = [{ name = "pydantic" }, { name = "starlette" }]

      [[package]]
      name = "uvicorn"
    TOML

    expect(doc["package"].map { |p| p["name"] }).to eq(%w[fastapi uvicorn])
    expect(doc["package"].first["source"]).to eq("registry" => "https://pypi.org/simple")
    expect(doc["package"].first["dependencies"].last).to eq("name" => "starlette")
  end

  it "parses multi-line and escaped strings" do
    doc = parse(%(a = """\nline1\nline2"""\nb = '''raw\\n'''\nc = "tab\\tquote\\"u\\u00e9"\n))

    expect(doc["a"]).to eq("line1\nline2")
    expect(doc["b"]).to eq("raw\\n")
    expect(doc["c"]).to eq("tab\tquote\"ué")
  end

  it "parses quoted keys" do
    doc = parse(%([packages]\n"django-environ" = "*"\n))
    expect(doc["packages"]).to eq("django-environ" => "*")
  end

  it "raises ParseError with a line number on unterminated strings" do
    expect { parse(%([project]\nname = "broken\n)) }
      .to raise_error(Analysis::Parsers::ParseError) { |e| expect(e.line).to eq(2) }
  end

  it "raises ParseError on garbage" do
    expect { parse("this is not toml") }.to raise_error(Analysis::Parsers::ParseError)
    expect { parse("a = [1, 2") }.to raise_error(Analysis::Parsers::ParseError)
    expect { parse("[a]\nb = 1\n[a.b]\n") }.to raise_error(Analysis::Parsers::ParseError)
  end
end
