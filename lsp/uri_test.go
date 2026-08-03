package lsp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/fs"
	"runtime"
	"strings"
	"testing"
)

func TestFileURIToPath(t *testing.T) {
	tests := []struct {
		name string
		uri  string
		goos string
		want string
	}{
		{
			name: "Windows drive",
			uri:  "file:///C:/project/lib.jq",
			goos: "windows",
			want: `C:\project\lib.jq`,
		},
		{
			name: "Windows percent encoding",
			uri:  "file:///C:/My%20Project/lib.jq",
			goos: "windows",
			want: `C:\My Project\lib.jq`,
		},
		{
			name: "Windows UNC",
			uri:  "file://server/share/lib.jq",
			goos: "windows",
			want: `\\server\share\lib.jq`,
		},
		{
			name: "Unix",
			uri:  "file:///home/user/lib.jq",
			goos: "linux",
			want: "/home/user/lib.jq",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := fileURIToPath(tt.uri, tt.goos)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Fatalf("fileURIToPath(%q, %q) = %q, want %q", tt.uri, tt.goos, got, tt.want)
			}
		})
	}
}

func TestIncludeFromWindowsFileURI(t *testing.T) {
	const (
		testURI = "file:///C:/project/test.jq"
		testJQ  = "include \"lib\";\n\nexternal\n"
		libJQ   = "def external: 42;\n"
	)

	libPath, err := fileURIToPath("file:///C:/project/lib.jq", runtime.GOOS)
	if err != nil {
		t.Fatal(err)
	}

	requests := []any{
		map[string]any{"jsonrpc": "2.0", "id": 0, "method": "initialize"},
		map[string]any{
			"jsonrpc": "2.0",
			"method":  "textDocument/didOpen",
			"params": map[string]any{"textDocument": map[string]any{
				"uri": testURI, "languageId": "jq", "version": 1, "text": testJQ,
			}},
		},
	}

	stdin := &bytes.Buffer{}
	for _, request := range requests {
		b, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(stdin, "Content-Length: %d\r\n\r\n", len(b))
		stdin.Write(b)
	}

	stdout := &bytes.Buffer{}
	_, err = Run(Env{
		Version: "test-version",
		ReadFile: func(path string) ([]byte, error) {
			if path == libPath {
				return []byte(libJQ), nil
			}
			return nil, fs.ErrNotExist
		},
		Stdin:  stdin,
		Stdout: stdout,
		Stderr: &bytes.Buffer{},
	})
	if err != nil {
		t.Fatal(err)
	}

	output := stdout.String()
	if strings.Contains(output, "external not found") {
		t.Fatalf("unexpected missing-function diagnostic:\n%s", output)
	}
	if !strings.Contains(output, `"diagnostics":[]`) {
		t.Fatalf("expected empty diagnostics:\n%s", output)
	}
}
