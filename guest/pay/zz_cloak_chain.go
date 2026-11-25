// Regents Cloak (guest/pay/zz_cloak_chain.go): the chain read of cloak-pay's
// V frame (docs/zkapi-mac-side.md, section 1), added to the mainnet daemon's
// zkapi package by go build -overlay, as it reads the funding handler's
// configuration and RPC, which the package keeps to itself.
package zkapi

import (
	"context"
	"encoding/hex"
	"errors"
	"math/big"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/crypto"
)

var (
	chainPaused = "0x" + hex.EncodeToString(crypto.Keccak256([]byte("paused()"))[:4])
	chainNotes  = "0x" + hex.EncodeToString(crypto.Keccak256([]byte("notes(uint32)"))[:4])
	// The vault's NoteStatus, in its order (protocol/contracts/src/libraries/Types.sol).
	chainNoteStatuses = []string{"uninitialized", "active", "pending_withdrawal", "closed"}
)

// ChainView is the chain at one block: the block's number and time, the
// vault's paused(), the funding address's ETH in wei, and, for a note, the
// vault's record of it.
type ChainView struct {
	Block      uint64     `json:"block"`
	Time       uint64     `json:"time"`
	Paused     bool       `json:"paused"`
	BalanceWei string     `json:"balance_wei"`
	Note       *ChainNote `json:"note,omitempty"`
}

// ChainNote is the vault's notes(noteId): its status and its expiry, in
// seconds since 1970.
type ChainNote struct {
	Status   string `json:"status"`
	ExpiryTs uint64 `json:"expiry_ts"`
}

// ReadChain reads the chain at the block eth_getBlockByNumber "latest" gives,
// every value at that block's number, through the funding handler's RPC: the
// daemon's own route, through Tor. note is the wallet's note, nil for none.
// It checks the RPC's network first, as every read of the funding address
// does, and reads the address as GET /admin/funding/address does, which
// makes its key on the first read. A value that does not read fails the
// whole read.
func (h *FundingHandler) ReadChain(ctx context.Context, note *uint32) (ChainView, error) {
	config, err := h.config(ctx)
	if err != nil {
		return ChainView{}, err
	}
	if err := h.assertAddressChain(ctx, config); err != nil {
		return ChainView{}, err
	}
	h.mu.Lock()
	record, err := h.loadAddress(config)
	h.mu.Unlock()
	if err != nil {
		return ChainView{}, err
	}
	var latest struct {
		Number    string `json:"number"`
		Timestamp string `json:"timestamp"`
	}
	if err := h.addressRPC(ctx, config, "eth_getBlockByNumber", []any{"latest", false}, &latest); err != nil {
		return ChainView{}, err
	}
	number, err := addressHexUint(latest.Number)
	if err != nil || !number.IsUint64() {
		return ChainView{}, errors.New("invalid latest block")
	}
	timestamp, err := addressHexUint(latest.Timestamp)
	if err != nil || !timestamp.IsUint64() {
		return ChainView{}, errors.New("invalid latest block")
	}
	block := "0x" + number.Text(16)
	paused, err := h.addressUintCall(ctx, config, config.Contract, chainPaused, block)
	if err != nil {
		return ChainView{}, err
	}
	if paused.Cmp(big.NewInt(1)) > 0 {
		return ChainView{}, errors.New("invalid vault pause state")
	}
	balance, err := h.addressQuantity(ctx, config, "eth_getBalance", []any{record.Address, block})
	if err != nil {
		return ChainView{}, err
	}
	view := ChainView{Block: number.Uint64(), Time: timestamp.Uint64(), Paused: paused.Sign() == 1, BalanceWei: balance.String()}
	if note != nil {
		var encoded string
		data := chainNotes + addressABIWord(strconv.FormatUint(uint64(*note), 16))
		if err := h.addressRPC(ctx, config, "eth_call", []any{map[string]string{"to": config.Contract, "data": data}, block}, &encoded); err != nil {
			return ChainView{}, err
		}
		if view.Note, err = chainNote(encoded); err != nil {
			return ChainView{}, err
		}
	}
	return view, nil
}

// chainNote reads notes(noteId)'s four words: the commitment, the deposit,
// the expiry (a uint64) and the status (the enum, a uint8).
func chainNote(encoded string) (*ChainNote, error) {
	digits, prefixed := strings.CutPrefix(encoded, "0x")
	raw, err := hex.DecodeString(digits)
	if !prefixed || err != nil || len(raw) != 4*32 {
		return nil, errors.New("invalid vault note")
	}
	expiry, status := new(big.Int).SetBytes(raw[64:96]), new(big.Int).SetBytes(raw[96:128])
	if !expiry.IsUint64() || !status.IsInt64() || status.Int64() >= int64(len(chainNoteStatuses)) {
		return nil, errors.New("invalid vault note")
	}
	return &ChainNote{Status: chainNoteStatuses[status.Int64()], ExpiryTs: expiry.Uint64()}, nil
}

// isClosedNoteOnChain checks notes(noteId) on-chain at "latest" without
// acquiring h.mu, so QuoteAddressReturn can safely allow public ETH transfers
// after an expired note was closed on-chain while the local companion still
// reports has_note=true.
func (h *FundingHandler) isClosedNoteOnChain(ctx context.Context, config fundingConfig, noteID uint32) bool {
	var encoded string
	data := chainNotes + addressABIWord(strconv.FormatUint(uint64(noteID), 16))
	if err := h.addressRPC(ctx, config, "eth_call", []any{map[string]string{"to": config.Contract, "data": data}, "latest"}, &encoded); err != nil {
		return false
	}
	note, err := chainNote(encoded)
	return err == nil && note != nil && note.Status == "closed"
}

// WithdrawalFeeEstimate is a read-only, non-locking estimate of the Ethereum
// gas fee needed for mutualClose using live block fees and wallet balance,
// without writing withdrawal_pending or requesting companion clearance.
type WithdrawalFeeEstimate struct {
	BalanceWei     string `json:"balance_wei"`
	GasLimit       uint64 `json:"gas_limit"`
	ExpectedFeeWei string `json:"expected_fee_wei"`
	RequiredFeeWei string `json:"required_fee_wei"`
	FeeReserveWei  string `json:"fee_reserve_wei"`
	ShortfallWei   string `json:"shortfall_wei"`
}

// Conservative padded gas ceiling for Groth16 BN254 + 32-level Merkle
// mutualClose on Ethereum Mainnet (~350k–420k actual gas; paddedAddressGas
// computes gas*1.2 + 50k ≈ 470k–554k). Using 600,000 keeps prechecks above
// the real quote's required fee so neither preview nor auto-withdraw locks
// spending only to hit a gas shortfall.
const withdrawalPreviewGasLimit uint64 = 600_000

// EstimateWithdrawalFee reads live Ethereum fees and the funding address's ETH
// balance without mutating disk state or contacting the companion's withdrawal
// reservation endpoint.
func (h *FundingHandler) EstimateWithdrawalFee(ctx context.Context) (WithdrawalFeeEstimate, error) {
	config, err := h.config(ctx)
	if err != nil {
		return WithdrawalFeeEstimate{}, err
	}
	if err := h.assertAddressChain(ctx, config); err != nil {
		return WithdrawalFeeEstimate{}, err
	}
	h.mu.Lock()
	record, err := h.loadAddress(config)
	h.mu.Unlock()
	if err != nil {
		return WithdrawalFeeEstimate{}, err
	}
	fees, err := h.addressLowFees(ctx, config, withdrawalPreviewGasLimit)
	if err != nil {
		return WithdrawalFeeEstimate{}, err
	}
	balance, err := h.addressQuantity(ctx, config, "eth_getBalance", []any{record.Address, "pending"})
	if err != nil {
		return WithdrawalFeeEstimate{}, err
	}
	gasInt := new(big.Int).SetUint64(withdrawalPreviewGasLimit)
	expected := new(big.Int).Mul(gasInt, fees.Expected)
	required := new(big.Int).Mul(gasInt, fees.Minimum)
	reserve := new(big.Int).Mul(gasInt, fees.Max)
	return WithdrawalFeeEstimate{
		BalanceWei:     balance.String(),
		GasLimit:       withdrawalPreviewGasLimit,
		ExpectedFeeWei: expected.String(),
		RequiredFeeWei: required.String(),
		FeeReserveWei:  reserve.String(),
		ShortfallWei:   positiveDifference(reserve, balance).String(),
	}, nil
}
