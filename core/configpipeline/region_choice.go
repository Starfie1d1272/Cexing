package configpipeline

import (
	"errors"
	"unicode/utf8"
)

// RegionChoice is host-owned selection intent, carried with successful provenance.
// It never participates in YAML transformation or refers to another version.
type RegionChoice struct {
	Pending  string                `json:"pending"`
	Previous *RegionPreviousChoice `json:"previous,omitempty"`
}
type RegionPreviousChoice struct {
	Selector string  `json:"selector"`
	Name     string  `json:"name"`
	Observed *string `json:"observed,omitempty"`
}

func CheckRegionChoice(choice *RegionChoice) error {
	if choice == nil {
		return nil
	}
	valid := func(s string) bool { return len(s) <= 4096 && utf8.ValidString(s) }
	if !valid(choice.Pending) {
		return errors.New("REGION_CHOICE_INVALID")
	}
	if p := choice.Previous; p != nil {
		if p.Selector == "" || p.Name == "" || !valid(p.Selector) || !valid(p.Name) || (p.Observed != nil && !valid(*p.Observed)) {
			return errors.New("REGION_CHOICE_INVALID")
		}
	}
	return nil
}
