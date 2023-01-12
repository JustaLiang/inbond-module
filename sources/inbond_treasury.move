module injoy_labs::inbond_treasury {
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::signer;
    use aptos_framework::voting;
    use aptos_std::option;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table::{Self, Table};
    use std::error;

    /// -----------------
    /// Errors
    /// -----------------

    const E_TREASURY_NOT_FOUND: u64 = 0;
    const E_RECORDS_NOT_FOUND: u64 = 1;
    const E_TREASURY_NO_GAP: u64 = 2;
    const E_ALREADY_VOTED: u64 = 3;

    /// -----------------
    /// Resources
    /// -----------------

    struct RecordKey has copy, drop, store {
        investor_addr: address,
        proposal_id: u64,
    }

    struct VotingRecords has key {
        min_voting_threshold: u128,
        voting_duration_secs: u64,
        votes: Table<RecordKey, bool>
    }

    struct Treasury<phantom CoinType> has key {        
        funding: Coin<CoinType>,
        max_funding_supply: u64,
    }

    struct VotingPower has key {
        voting_power_map: SimpleMap<address, u64>,
    }

    struct WithdrawalProposal has store, drop {
        withdrawal_amount: u64,
        beneficiary: address,
    }

    /// -----------------
    /// Getter functions
    /// -----------------
    
    public fun has_treasury<CoinType>(addr: address): bool {
        exists<Treasury<CoinType>>(addr)
    }
    spec has_treasury {
        aborts_if false;
    }

    public fun treasury_supply<CoinType>(founder: address): u64 acquires Treasury {
        check_treasury<CoinType>(founder);
        let treasury = borrow_global<Treasury<CoinType>>(founder);
        coin::value<CoinType>(&treasury.funding)
    }
    spec treasury_supply {
        aborts_if !exists<Treasury<CoinType>>(founder);
    }

    public fun treasury_max_supply<CoinType>(founder: address): u64 acquires Treasury {
        assert!(
            has_treasury<CoinType>(founder),
            error::not_found(E_TREASURY_NOT_FOUND),
        );
        borrow_global<Treasury<CoinType>>(founder).max_funding_supply        
    }
    spec treasury_supply {
        aborts_if !exists<Treasury<CoinType>>(founder);
    }

    /// -----------------
    /// Public functions
    /// -----------------

    public entry fun create_treasury<CoinType>(
        founder: &signer,
        max_funding_supply: u64,
        min_voting_threshold: u128,
        voting_duration_secs: u64,
    ) {
        voting::register<WithdrawalProposal>(founder);
        move_to(founder, Treasury<CoinType> {
            funding: coin::zero<CoinType>(),
            max_funding_supply,
        });
        move_to(founder, VotingRecords {
            min_voting_threshold,
            voting_duration_secs,
            votes: table::new(),
        });
    }
    spec create_treasury {
        let founder_addr = signer::address_of(founder);
        aborts_if exists<Treasury<CoinType>>(founder_addr);

        ensures exists<Treasury<CoinType>>(founder_addr);
    }

    public entry fun fund<CoinType>(
        investor: &signer,
        founder: address,
        amount: u64,
    ) acquires Treasury, VotingPower {
        check_treasury<CoinType>(founder);
        let treasury = borrow_global_mut<Treasury<CoinType>>(founder);
        let gap = treasury.max_funding_supply - coin::value(&treasury.funding);
        let amount = if (gap >= amount) {
            amount
        } else {
            gap
        };
        assert!(amount > 0, error::aborted(E_TREASURY_NO_GAP));
        let coin = coin::withdraw(investor, amount);
        coin::merge(&mut treasury.funding, coin);
        let investor_addr = std::signer::address_of(investor);
        if (!exists<VotingPower>(investor_addr)) {
            move_to(investor, VotingPower {
                voting_power_map: simple_map::create(),
            });
        };
        let voting_power_map = borrow_global_mut<VotingPower>(investor_addr).voting_power_map;
        simple_map::add(&mut voting_power_map, founder, amount);
    }

    public entry fun propose(
        founder: &signer,
        withdrawal_amount: u64,
        beneficiary: address,
        execution_hash: vector<u8>,
    ) acquires VotingRecords {
        let founder_addr = std::signer::address_of(founder);
        let records = borrow_global<VotingRecords>(founder_addr);

        voting::create_proposal(
            founder_addr,
            founder_addr,
            WithdrawalProposal { withdrawal_amount, beneficiary },
            execution_hash,
            records.min_voting_threshold,
            records.voting_duration_secs,
            option::none(),
            simple_map::create(),
        );
    }

    public entry fun vote(
        investor: &signer,
        founder: address,
        proposal_id: u64,
        should_pass: bool,
    ) acquires VotingRecords, VotingPower {
        let investor_addr = std::signer::address_of(investor);
        let record_key = RecordKey {
            investor_addr,
            proposal_id,
        };
        let records = borrow_global<VotingRecords>(founder);
        assert!(
            !table::contains(&records.votes, record_key),
            error::invalid_argument(E_ALREADY_VOTED),
        );
        let voting_power = borrow_global<VotingPower>(investor_addr);
        let num_votes = simple_map::borrow(&voting_power.voting_power_map, &founder);

        voting::vote(
            &empty_proposal(),
            copy founder,
            proposal_id,
            *num_votes,
            should_pass,
        );
    }

    public fun withdraw<CoinType>(
        founder: address,
        proposal: WithdrawalProposal,
    ) acquires Treasury {
        check_treasury<CoinType>(founder);
        let treasury = borrow_global_mut<Treasury<CoinType>>(founder);
        let coin = coin::extract(&mut treasury.funding, proposal.withdrawal_amount);
        coin::deposit(proposal.beneficiary, coin);
    }

    /// -----------------
    /// Private functions
    /// -----------------

    fun check_treasury<CoinType>(addr: address) {
        assert!(
            exists<Treasury<CoinType>>(addr),
            error::not_found(E_TREASURY_NOT_FOUND),
        );       
    }

    fun check_records(addr: address) {
        assert!(
            exists<VotingRecords>(addr),
            error::not_found(E_RECORDS_NOT_FOUND),
        );
    }

    fun empty_proposal(): WithdrawalProposal {
        WithdrawalProposal {
            withdrawal_amount: 0,
            beneficiary: @0x0,
        }
    }
}