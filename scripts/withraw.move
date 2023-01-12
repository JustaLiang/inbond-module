script {
    use injoy_labs::inbond_treasury;
    use aptos_framework::voting;

    fun withraw<CoinType>(founder: address, proposal_id: u64) {
        let withdrawal_proposal = voting::resolve(founder, proposal_id);
        inbond_treasury::withdraw<CoinType>(founder, withdrawal_proposal);
    } 
}