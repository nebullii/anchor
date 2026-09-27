package cli

import (
	"fmt"
	"strconv"
	"strings"
)

// flagDef describes one flag. Flags may appear anywhere among the
// positional arguments (unlike the stdlib flag package), which is what
// people expect from `anchor deploy my-app --follow`.
type flagDef struct {
	Name  string
	Short string
	Value bool // takes a value (otherwise boolean)
	Usage string
}

type parsedArgs struct {
	values map[string]string
	bools  map[string]bool
	args   []string
}

func (p parsedArgs) Bool(name string) bool     { return p.bools[name] }
func (p parsedArgs) String(name string) string { return p.values[name] }

func (p parsedArgs) Int(name string) (int64, error) {
	v := p.values[name]
	if v == "" {
		return 0, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("--%s must be a positive number, got %q", name, v)
	}
	return n, nil
}

func (p parsedArgs) Arg(i int) string {
	if i < len(p.args) {
		return p.args[i]
	}
	return ""
}

func parseFlags(command string, argv []string, defs []flagDef) (parsedArgs, error) {
	out := parsedArgs{values: map[string]string{}, bools: map[string]bool{}}
	lookup := map[string]flagDef{}
	for _, d := range defs {
		lookup["--"+d.Name] = d
		if d.Short != "" {
			lookup["-"+d.Short] = d
		}
	}

	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		if arg == "--" {
			out.args = append(out.args, argv[i+1:]...)
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			out.args = append(out.args, arg)
			continue
		}

		name, inline, hasInline := strings.Cut(arg, "=")
		def, ok := lookup[name]
		if !ok {
			return out, fmt.Errorf("unknown flag %s for `anchor %s` (see `anchor %s --help`)", name, command, command)
		}
		if !def.Value {
			if hasInline {
				b, err := strconv.ParseBool(inline)
				if err != nil {
					return out, fmt.Errorf("flag --%s does not take a value", def.Name)
				}
				out.bools[def.Name] = b
			} else {
				out.bools[def.Name] = true
			}
			continue
		}
		if hasInline {
			out.values[def.Name] = inline
			continue
		}
		if i+1 >= len(argv) {
			return out, fmt.Errorf("flag --%s needs a value", def.Name)
		}
		i++
		out.values[def.Name] = argv[i]
	}
	return out, nil
}

// Flags shared by several commands.
var (
	flagJSON    = flagDef{Name: "json", Usage: "print raw JSON from the API"}
	flagProject = flagDef{Name: "project", Short: "p", Value: true, Usage: "project slug or id"}
	flagHelp    = flagDef{Name: "help", Short: "h", Usage: "show help"}
)
