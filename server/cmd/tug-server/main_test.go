package main

import (
	"os"
	"testing"
)

func TestRunHelpVersionAndInvalidConfiguration(t *testing.T) {
	original := os.Args
	defer func() { os.Args = original }()
	for _, testCase := range []struct {
		arguments []string
		exitCode  int
	}{
		{[]string{"tug-server", "--help"}, 0},
		{[]string{"tug-server", "--version"}, 0},
		{[]string{"tug-server", "--unexpected-option"}, 2},
	} {
		os.Args = testCase.arguments
		if actual := run(); actual != testCase.exitCode {
			t.Fatalf("expected exit %d, got %d", testCase.exitCode, actual)
		}
	}
}
