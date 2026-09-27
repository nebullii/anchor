// Command anchor is the CLI for Anchor: deploy, watch and roll back
// projects from the terminal. See README.md.
package main

import (
	"os"

	"github.com/nebullii/anchor/cli/internal/cli"
)

func main() {
	os.Exit(cli.NewApp().Run(os.Args[1:]))
}
