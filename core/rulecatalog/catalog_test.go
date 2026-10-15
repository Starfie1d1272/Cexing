package rulecatalog

import (
	"strings"
	"testing"
)

func TestAIIncludesMaintainedSubsetsAndSharedServicePresets(t *testing.T) {
	aggregate := map[string]bool{}
	for _, rule := range Rules("category-ai-!cn") {
		aggregate[rule] = true
	}
	for _, service := range []string{"openai", "anthropic", "google-deepmind", "cursor", "github-copilot", "groq", "huggingface", "jetbrains-ai", "perplexity", "poe", "windsurf", "xai"} {
		for _, rule := range Rules(service) {
			if !aggregate[rule] {
				t.Fatalf("AI aggregate omitted maintained child %s", service)
			}
		}
	}
	for _, domain := range []string{"openrouter.ai", "mistral.ai", "midjourney.com", "cohere.com", "copilot.microsoft.com"} {
		if !aggregate["DOMAIN-SUFFIX,"+domain] {
			t.Fatalf("AI category missing %s", domain)
		}
	}
	text := strings.Join(Rules("openai"), "\n")
	for _, fragment := range []string{"chatgpt.livekit.cloud", "openaiassets.blob.core.windows.net", "DOMAIN-REGEX,"} {
		if !strings.Contains(text, fragment) {
			t.Fatal("OpenAI CDN/API/voice coverage lost")
		}
	}
	for _, id := range []string{"netflix", "disney", "spotify"} {
		if !Known(id) || len(Rules(id)) == 0 {
			t.Fatal("empty optional service preset")
		}
	}
}
