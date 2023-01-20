module injoy_labs::inbond_treasury {
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::signer;
    use aptos_framework::voting;
    use aptos_std::option;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table::{Self, Table};
    use std::error;

    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;

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
        votes: Table<RecordKey, bool>,
    }

    struct Treasury<phantom FundingType> has key {        
        funding: Coin<FundingType>,
        target_funding_supply: u64,
    }

    struct FounderVault<phantom VaultType> has key {
        vault: Coin<VaultType>,
    }

    struct InvestmentProof has key {
        voting_powers: SimpleMap<address, u64>,
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
        borrow_global<Treasury<CoinType>>(founder).target_funding_supply        
    }
    spec treasury_supply {
        aborts_if !exists<Treasury<CoinType>>(founder);
    }

    /// -----------------
    /// Public functions
    /// -----------------

    public entry fun create_treasury<FundingType, VaultType>(
        founder: &signer,
        target_funding_supply: u64,
        min_voting_threshold: u128,
        voting_duration_secs: u64,
        vault_size: u64,
    ) {
        voting::register<WithdrawalProposal>(founder);
        move_to(founder, Treasury<FundingType> {
            funding: coin::zero<FundingType>(),
            target_funding_supply,
        });
        move_to(founder, VotingRecords {
            min_voting_threshold,
            voting_duration_secs,
            votes: table::new(),
        });
        let coin = coin::withdraw<VaultType>(founder, vault_size);
        move_to(founder, FounderVault {
            vault: coin,
        });
    }
    spec create_treasury {
        pragma aborts_if_is_partial;
        let founder_addr = signer::address_of(founder);
        aborts_if exists<Treasury<FundingType>>(founder_addr);
        aborts_if exists<VotingRecords>(founder_addr);

        ensures exists<Treasury<FundingType>>(founder_addr);
        ensures exists<VotingRecords>(founder_addr);
    }

    public entry fun fund<CoinType>(
        investor: &signer,
        founder: address,
        amount: u64,
    ) acquires Treasury, InvestmentProof {
        check_treasury<CoinType>(founder);
        let treasury = borrow_global_mut<Treasury<CoinType>>(founder);
        let gap = treasury.target_funding_supply - coin::value(&treasury.funding);
        let amount = if (gap >= amount) {
            amount
        } else {
            gap
        };
        assert!(amount > 0, error::aborted(E_TREASURY_NO_GAP));
        let coin = coin::withdraw(investor, amount);
        coin::merge(&mut treasury.funding, coin);
        let investor_addr = std::signer::address_of(investor);
        if (!exists<InvestmentProof>(investor_addr)) {
            move_to(investor, InvestmentProof {
                voting_powers: simple_map::create(),
            });
        };
        let voting_powers = &mut borrow_global_mut<InvestmentProof>(investor_addr).voting_powers;
        simple_map::add(voting_powers, founder, amount);
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
    ) acquires VotingRecords, InvestmentProof {
        let investor_addr = std::signer::address_of(investor);
        let record_key = RecordKey {
            investor_addr,
            proposal_id,
        };
        let records = borrow_global_mut<VotingRecords>(founder);
        assert!(
            !table::contains(&records.votes, record_key),
            error::invalid_argument(E_ALREADY_VOTED),
        );
        table::add(&mut records.votes, record_key, true);

        let proof = borrow_global<InvestmentProof>(investor_addr);
        let num_votes = simple_map::borrow(&proof.voting_powers, &founder);

        voting::vote<WithdrawalProposal>(
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

    public entry fun redeem_all<CoinType>(
        investor: &signer,
        founder: address,
    ) acquires Treasury, InvestmentProof, VotingRecords {
        let investor_addr = std::signer::address_of(investor);
        let treasury = borrow_global_mut<Treasury<CoinType>>(founder);
        let voting_power = borrow_global_mut<InvestmentProof>(investor_addr);
        let (_, num_votes) = simple_map::remove(&mut voting_power.voting_powers, &founder);
        let coin = coin::extract(&mut treasury.funding, num_votes * 9 / 10);
        coin::deposit(investor_addr, coin);

        let records = borrow_global_mut<VotingRecords>(founder);
        records.min_voting_threshold = records.min_voting_threshold - (num_votes as u128);
    }

    public entry fun convert_all<FundingType, VaultType>(
        investor: &signer,
        founder: address,
    ) acquires Treasury, InvestmentProof, VotingRecords, FounderVault {
        let investor_addr = std::signer::address_of(investor);
        let treasury = borrow_global_mut<Treasury<FundingType>>(founder);
        let proof = borrow_global_mut<InvestmentProof>(investor_addr);
        let records = borrow_global_mut<VotingRecords>(founder);
        let vault = borrow_global_mut<FounderVault<VaultType>>(founder);

        let (_, num_votes) = simple_map::remove(&mut proof.voting_powers, &founder);

        let input_coin = coin::extract(&mut treasury.funding, num_votes);
        records.min_voting_threshold = records.min_voting_threshold - (num_votes as u128);

        let output_amount = convertable_amount(coin::value(&input_coin));

        let output_coin = coin::extract(&mut vault.vault, output_amount);

        coin::deposit(founder, input_coin);
        coin::deposit(investor_addr, output_coin);
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

    fun convertable_amount(input: u64): u64 {
        input
    }

    #[test_only]
    fun setup_account(account: &signer): address {
        use aptos_framework::account;
        
        let addr = signer::address_of(account);
        account::create_account_for_test(addr);
        addr
    }

    #[test_only]
    public fun setup_voting(
        founder: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires Treasury, InvestmentProof, VotingRecords
    {
        use aptos_framework::coin::{Self, FakeMoney};
        use aptos_framework::timestamp;
        use std::vector;

        timestamp::set_time_has_started_for_testing(founder);

        let founder_addr = setup_account(founder);
        let yes_voter_addr = setup_account(yes_voter);
        let no_voter_addr = setup_account(no_voter);

        coin::create_fake_money(founder, yes_voter, 100);
        coin::register<FakeMoney>(no_voter);
        coin::transfer<FakeMoney>(founder, yes_voter_addr, 20);
        coin::transfer<FakeMoney>(founder, no_voter_addr, 10);

        // create treasury
        create_treasury<FakeMoney, FakeMoney>(founder, 30, 10, 10000, 30);

        // fund
        fund<FakeMoney>(yes_voter, founder_addr, 20);
        fund<FakeMoney>(no_voter, founder_addr, 10);

        // create proposal
        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        propose(founder, 20, founder_addr, execution_hash);
    }

    #[test(founder = @0x1, yes_voter = @0x234, no_voter = @0x345)]
    public entry fun test_voting(
        founder: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires Treasury, InvestmentProof, VotingRecords {
        use aptos_framework::coin::{Self, FakeMoney};
        use aptos_framework::timestamp;

        let founder_addr = signer::address_of(founder);

        setup_voting(founder, yes_voter, no_voter);

        // vote
        vote(yes_voter, founder_addr, 0, true);
        vote(no_voter, founder_addr, 0, false);

        timestamp::update_global_time_for_test(100001000000);
        let proposal_state = voting::get_proposal_state<WithdrawalProposal>(founder_addr, 0);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, proposal_state);

        // resolve
        let withdrawal_proposal = voting::resolve<WithdrawalProposal>(founder_addr, 0);
        withdraw<FakeMoney>(founder_addr, withdrawal_proposal);

        assert!(voting::is_resolved<WithdrawalProposal>(founder_addr, 0), 2);
        assert!(coin::balance<FakeMoney>(founder_addr) == 60, 4);
    }

    #[test(founder = @0x1, yes_voter = @0x234, no_voter = @0x345)]
    public entry fun test_redeem_all(
        founder: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires Treasury, InvestmentProof, VotingRecords {
        use aptos_framework::coin::{Self, FakeMoney};

        setup_voting(founder, yes_voter, no_voter);

        // redeem all
        redeem_all<FakeMoney>(no_voter, signer::address_of(founder));

        assert!(coin::balance<FakeMoney>(signer::address_of(no_voter)) == 9, 1);
    }

    #[test(founder = @0x1, yes_voter = @0x234, no_voter = @0x345)]
    #[expected_failure(abort_code = 0x10003, location = injoy_labs::inbond_treasury)]
    public entry fun test_cannot_double_vote(
        founder: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires Treasury, InvestmentProof, VotingRecords {
        setup_voting(founder, yes_voter, no_voter);

        // Double voting should throw an error.
        vote(yes_voter, signer::address_of(founder), 0, true);
        vote(yes_voter, signer::address_of(founder), 0, true);
    }
    
}