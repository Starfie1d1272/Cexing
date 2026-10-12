package configpipeline

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	_ "github.com/metacubex/mihomo/hub/executor" // provides config's linked temporary-state rollback
)

// The locked Mihomo parser mutates globals and allocates runtime objects. Run
// this integration check in a disposable child process, never the app runtime.
func TestLockedMihomoValidator(t *testing.T) {
	if os.Getenv("CONFIGPIPELINE_PARSER_CHILD") == "1" {
		c := compiler()
		c.Validate = func(_ context.Context, data []byte) error { _, err := config.Parse(data); return err }
		if _, err := c.Compile(context.Background(), Request{Original: []byte(original)}); err != nil {
			t.Fatal(err)
		}
		invalid := strings.Replace(original, "type: ss", "type: nonexistent-protocol", 1)
		if _, err := c.Compile(context.Background(), Request{Original: []byte(invalid)}); err == nil {
			t.Fatal("locked core accepted invalid protocol")
		}
		providerOnly := `proxy-providers:
  feed:
    type: inline
    payload: [{name: node, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic}]
proxy-groups: [{name: pick, type: select, use: [feed]}]
rules: ['MATCH,pick']
`
		if _, err := c.Compile(context.Background(), Request{Original: []byte(providerOnly)}); err != nil {
			t.Fatal(err)
		}
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestLockedMihomoValidator$", "-test.v")
	cmd.Env = append(os.Environ(), "CONFIGPIPELINE_PARSER_CHILD=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("locked parser integration: %v\n%s", err, out)
	}
}
