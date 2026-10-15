// Package rulecatalog contains pinned, offline public service classifications.
// Generated domain data is MIT licensed; see third_party/routing-rules.
package rulecatalog

import (
	_ "embed"
	"encoding/json"
	"sort"
)

//go:embed data/domains.json
var domainsJSON []byte
var domains = func() map[string][]string {
	var data map[string][]string
	if err := json.Unmarshal(domainsJSON, &data); err != nil {
		panic("invalid bundled public rules")
	}
	return data
}()

type Service struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

var Services = []Service{
	{"category-ai-!cn", "AI 服务"}, {"openai", "ChatGPT / OpenAI"}, {"anthropic", "Claude"},
	{"google-deepmind", "Gemini / Google AI"}, {"cursor", "Cursor"}, {"github-copilot", "GitHub Copilot"},
	{"groq", "Groq"}, {"huggingface", "Hugging Face"}, {"jetbrains-ai", "JetBrains AI"},
	{"perplexity", "Perplexity"}, {"poe", "Poe"}, {"windsurf", "Windsurf"}, {"xai", "Grok / xAI"},
	{"netflix", "Netflix"}, {"disney", "Disney+"}, {"spotify", "Spotify"},
}

func Rules(id string) []string { return append([]string(nil), domains[id]...) }
func Known(id string) bool {
	for _, s := range Services {
		if s.ID == id {
			return true
		}
	}
	return false
}
func Categories() []string {
	ids := []string{}
	for id := range domains {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}
