script {
    use injoy_labs::inbond;
    use aptos_framework::voting;

    fun withraw<CoinType>(founder: address, proposal_id: u64) {
        let withdrawal_proposal = voting::resolve<inbond::WithdrawalProposal>(founder, proposal_id);
        inbond::withdraw<CoinType>(founder, withdrawal_proposal);
    } 
}