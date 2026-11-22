// Regents Cloak (guest/pay/zz_cloak_prices.go): the prices cloak-pay answers
// a "GET /cloak/prices" call with (docs/zkapi-mac-side.md, section 1), added
// to the mainnet daemon's zkapi package by go build -overlay, as it reads
// with the client's own transport and provider address, which the package
// keeps to itself.
package zkapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

// ModelPrice is what one model costs in the provider's public list: US
// dollars a token, sent and answered, as the list writes them.
type ModelPrice struct {
	ID         string `json:"id"`
	Prompt     string `json:"prompt"`
	Completion string `json:"completion"`
}

// ModelPrices reads the provider's public list of models, the one Models
// reads for their names, for what each costs. As there, neither the chosen
// model nor any credential is sent.
func (c *Client) ModelPrices(ctx context.Context) ([]ModelPrice, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.config.InferenceBaseURL+"/models", nil)
	if err != nil {
		return nil, &Error{http.StatusBadGateway, "models_unavailable"}
	}
	req.Header.Set("Accept", "application/json")
	res, err := c.inference.Do(req)
	if err != nil {
		return nil, &Error{http.StatusBadGateway, "models_unavailable"}
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, (16<<20)+1))
	var catalog struct {
		Data []struct {
			ID      string `json:"id"`
			Pricing struct {
				Prompt     string `json:"prompt"`
				Completion string `json:"completion"`
			} `json:"pricing"`
		} `json:"data"`
	}
	if err != nil || res.StatusCode != http.StatusOK || len(raw) > 16<<20 || json.Unmarshal(raw, &catalog) != nil || len(catalog.Data) == 0 {
		return nil, &Error{http.StatusBadGateway, "models_unavailable"}
	}
	prices := make([]ModelPrice, 0, len(catalog.Data))
	for _, model := range catalog.Data {
		if model.ID == "" || strings.TrimSpace(model.ID) != model.ID {
			return nil, &Error{http.StatusBadGateway, "models_unavailable"}
		}
		prices = append(prices, ModelPrice{model.ID, model.Pricing.Prompt, model.Pricing.Completion})
	}
	return prices, nil
}
