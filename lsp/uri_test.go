package lsp

import "testing"

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
