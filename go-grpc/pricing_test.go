package main

import "testing"

func TestParsePricingRules(t *testing.T) {
	tests := []struct {
		name string
		spec string
		want []pricingRule
	}{
		{"empty", "", nil},
		{"one rule", "002=EUR", []pricingRule{{suffix: "002", currency: "EUR"}}},
		{"spaces around a rule", " 002 = EUR ", []pricingRule{{suffix: "002", currency: "EUR"}}},
		{"two rules", "002=EUR,003=GBP", []pricingRule{
			{suffix: "002", currency: "EUR"},
			{suffix: "003", currency: "GBP"},
		}},
		{"malformed entries skipped", "002,=EUR,003=,004=JPY", []pricingRule{
			{suffix: "004", currency: "JPY"},
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parsePricingRules(tt.spec)
			if len(got) != len(tt.want) {
				t.Fatalf("parsePricingRules(%q) = %v, want %v", tt.spec, got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("rule %d = %v, want %v", i, got[i], tt.want[i])
				}
			}
		})
	}
}

func TestCurrencyFor(t *testing.T) {
	rules := parsePricingRules("002=EUR")
	tests := []struct {
		itemID string
		want   string
	}{
		{"a0000000-0000-0000-0000-000000000001", "USD"},
		{"a0000000-0000-0000-0000-000000000002", "EUR"},
		{"a0000000-0000-0000-0000-000000000003", "USD"},
		{"", "USD"},
		{"02", "USD"},
	}
	for _, tt := range tests {
		if got := currencyFor(rules, tt.itemID); got != tt.want {
			t.Errorf("currencyFor(%q) = %q, want %q", tt.itemID, got, tt.want)
		}
	}
}

// With no rules configured every item is priced in USD, which is the baseline
// the stack runs on.
func TestCurrencyForNoRules(t *testing.T) {
	if got := currencyFor(nil, "a0000000-0000-0000-0000-000000000002"); got != "USD" {
		t.Errorf("currencyFor with no rules = %q, want %q", got, "USD")
	}
}
