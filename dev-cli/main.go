package main

import (
	"context"
	"fmt"
	"os"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/cli"
)

func main() {
	if err := cli.Run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "playmesh-cli:", err)
		os.Exit(1)
	}
}
