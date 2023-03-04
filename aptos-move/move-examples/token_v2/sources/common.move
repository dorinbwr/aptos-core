module token_v2::common {
    use std::option::{Option, is_some};
    use aptos_framework::object::{Self, ExtendRef, TransferRef, DeleteRef, Object, ConstructorRef, object_from_extend_ref, object_from_transfer_ref, object_from_delete_ref, object_address, transfer_with_ref, generate_linear_transfer_ref, enable_ungated_transfer, disable_ungated_transfer, generate_extend_ref, generate_transfer_ref, generate_delete_ref, exists_at, is_owner, address_from_constructor_ref, address_to_object, address_from_extend_ref, address_from_transfer_ref, address_from_delete_ref};
    use std::option;
    use token_v2::collection::Collection;
    use std::string::{String, bytes};
    use std::vector;
    use std::string;
    use std::error;
    use std::signer::address_of;

    friend token_v2::collection;
    friend token_v2::coin;
    friend token_v2::token;

    /// The length of cap or ref flags vector is not 3.
    const EFLAGS_INCORRECT_LENGTH: u64 = 1;
    /// Object<T> (Resource T) does not exist.
    const EOBJECT_NOT_FOUND: u64 = 2;
    /// Not the owner.
    const ENOT_OWNER: u64 = 3;
    /// The fungible asset supply exists or does not exist for this asset object.
    const EFUNGIBLE_ASSET_SUPPLY: u64 = 4;
    /// Royalty percentage is invalid.
    const EINVALID_PERCENTAGE: u64 = 8;
    /// Name is invalid.
    const EINVALID_NAME: u64 = 9;
    /// The current_supply of token as fungible assets is not zero.
    const ECURRENT_SUPPLY_NON_ZERO: u64 = 10;
    /// Mint capability exists or does not exist.
    const EMINT_CAP: u64 = 11;
    /// Freeze capability exists does not exist.
    const EFREEZE_CAP: u64 = 12;
    /// Burn capability exists or does not exist.
    const EBURN_CAP: u64 = 13;
    /// Current supply overflow
    const ECURRENT_SUPPLY_OVERFLOW: u64 = 14;
    /// Current supply underflow
    const ECURRENT_SUPPLY_UNDERFLOW: u64 = 15;

    public fun assert_flags_length(flags: &vector<bool>) {
        assert!(vector::length(flags) == 3, error::invalid_argument(EFLAGS_INCORRECT_LENGTH));
    }

    public fun assert_valid_name(name: &String) {
        assert!(is_valid_name(name), error::invalid_argument(EINVALID_NAME));
    }

    /// Only allow human readable characters in naming.
    fun is_valid_name(name: &String): bool {
        if (string::length(name) == 0) {
            return false;
        };
        std::vector::all(bytes(name), |char| *char >= 32 && *char <= 126)
    }

    /// ================================================================================================================
    /// Royalty
    /// ================================================================================================================
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// The royalty of a token within this collection -- this optional
    struct Royalty has copy, drop, key {
        // The percentage of sale price considered as royalty.
        percentage: u8,
        /// The recipient of royalty payments. See the `shared_account` for how to handle multiple
        /// creators.
        payee_address: address,
    }

    public(friend) fun create_royalty(percentage: u8, payee_address: address): Royalty {
        assert!(percentage <= 100, error::invalid_argument(EINVALID_PERCENTAGE));
        Royalty { percentage, payee_address }
    }

    public(friend) fun init_royalty(object_signer: &signer, royalty: Royalty) {
        move_to(object_signer, royalty);
    }

    public(friend) fun remove_royalty(object_address: address) acquires Royalty {
        move_from<Royalty>(object_address);
    }

    public(friend) fun exists_royalty(object_address: address): bool {
        exists<Royalty>(object_address)
    }

    public fun get_royalty(object_addr: address): Option<Royalty> acquires Royalty {
        if (exists<Royalty>(object_addr)) {
            option::some(*borrow_global<Royalty>(object_addr))
        } else {
            option::none()
        }
    }

    public fun get_royalty_pencentage(royalty: &Royalty): u8 {
        royalty.percentage
    }

    public fun get_royalty_payee_address(royalty: &Royalty): address {
        royalty.payee_address
    }


    /// ================================================================================================================
    /// Fungible asset metadata
    /// ================================================================================================================
    struct Supply has copy, drop, store {
        current: u64,
        maximum: Option<u64>
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct FungibleAssetMetadata has drop, key {
        supply: Supply,
        asset_owner_caps: Caps
    }

    public fun new_supply(maximum: Option<u64>): Supply {
        Supply {
            current: 0,
            maximum
        }
    }

    public fun get_current_supply(supply: &Supply): u64 {
        supply.current
    }

    public fun get_maximum_supply(supply: &Supply): Option<u64> {
        supply.maximum
    }

    /// maximum = 0 means no maximum limit.
    public fun init_fungible_asset_metadata(object_signer: &signer, supply: Supply, cap_flags: vector<bool>) {
        move_to(object_signer,
            FungibleAssetMetadata {
                supply,
                asset_owner_caps: new_caps(address_of(object_signer), cap_flags)
            }
        );
    }

    public fun assert_fungible_asset_metadata_exists<T: key>(asset: &Object<T>) {
        assert!(fungible_asset_metadata_exists(asset), error::not_found(EFUNGIBLE_ASSET_SUPPLY));
    }

    public fun assert_fungible_asset_metadata_not_exists<T: key>(asset: &Object<T>) {
        assert!(!fungible_asset_metadata_exists(asset), error::already_exists(EFUNGIBLE_ASSET_SUPPLY));
    }

    public fun fungible_asset_metadata_exists<T: key>(asset: &Object<T>): bool {
        exists<FungibleAssetMetadata>(object_address(asset))
    }

    public fun remove_fungible_asset_metadata<T: key>(
        owner: &signer,
        asset: &Object<T>
    ) acquires FungibleAssetMetadata {
        assert!(is_owner(*asset, address_of(owner)), error::permission_denied(ENOT_OWNER));
        assert!(get_current_supply(borrow_supply(asset)) == 0, error::permission_denied(ECURRENT_SUPPLY_NON_ZERO));
        move_from<FungibleAssetMetadata>(object_address(asset));
    }

    public fun borrow_supply<T: key>(asset: &Object<T>): &Supply acquires FungibleAssetMetadata {
        assert_fungible_asset_metadata_exists(asset);
        let object_addr = object_address(asset);
        &borrow_global<FungibleAssetMetadata>(object_addr).supply
    }

    inline fun borrow_supply_mut<T: key>(asset: &Object<T>): &mut Supply acquires FungibleAssetMetadata {
        assert_fungible_asset_metadata_exists(asset);
        let object_addr = object_address(asset);
        &mut borrow_global_mut<FungibleAssetMetadata>(object_addr).supply
    }

    /// Increase the supply of fungible asset
    public fun increase_supply<T: key>(cap: &MintCap, asset: &Object<T>, amount: u64) acquires FungibleAssetMetadata {
        assert_mint_cap_and_asset_match(cap, asset);
        assert!(amount > 0);
        let supply = borrow_supply_mut(asset);
        if (option::is_some(&supply.maximum)) {
            let max = *option::borrow(&supply.maximum);
            assert!(max - supply.current <= amount, error::invalid_argument(ECURRENT_SUPPLY_OVERFLOW))
        };
        supply.current = supply.current + amount;
    }

    public fun decrease_supply<T: key>(cap: &BurnCap, asset: &Object<T>, amount: u64) acquires FungibleAssetMetadata {
        assert!(amount > 0);
        assert_burn_cap_and_asset_match(cap, asset);
        let supply = borrow_supply_mut(asset);
        assert!(supply.current >= amount, error::invalid_argument(ECURRENT_SUPPLY_UNDERFLOW));
        supply.current = supply.current - amount;
    }

    /// ================================================================================================================
    /// Capability functions
    /// ================================================================================================================
    struct MintCap has drop, store {
        asset_addr: address
    }

    struct FreezeCap has drop, store {
        asset_addr: address
    }

    struct BurnCap has drop, store {
        asset_addr: address
    }

    struct Caps has drop, store {
        mint: Option<MintCap>,
        freeze: Option<FreezeCap>,
        burn: Option<BurnCap>,
    }

    public fun new_caps(asset_addr: address, cap_flags: vector<bool>): Caps {
        assert_flags_length(&cap_flags);
        let enable_mint = *vector::borrow(&cap_flags, 0);
        let enable_freeze = *vector::borrow(&cap_flags, 1);
        let enable_burn = *vector::borrow(&cap_flags, 2);
        Caps {
            mint: if (enable_mint) { option::some(MintCap { asset_addr }) } else { option::none() },
            freeze: if (enable_freeze) { option::some(FreezeCap { asset_addr }) } else { option::none() },
            burn: if (enable_burn) { option::some(BurnCap { asset_addr }) } else { option::none() }
        }
    }

    inline fun borrow_caps<T: key>(asset: &Object<T>): &Caps acquires FungibleAssetMetadata {
        assert_fungible_asset_metadata_exists(asset);
        &borrow_global<FungibleAssetMetadata>(object_address(asset)).asset_owner_caps
    }

    inline fun borrow_caps_mut<T: key>(owner: &signer, asset: &Object<T>): &mut Caps acquires FungibleAssetMetadata {
        assert!(is_owner(*asset, address_of(owner)), error::permission_denied(ENOT_OWNER));
        assert_fungible_asset_metadata_exists(asset);
        &mut borrow_global_mut<FungibleAssetMetadata>(object_address(asset)).asset_owner_caps
    }

    public fun caps_contain_mint<T: key>(asset: &Object<T>): bool acquires FungibleAssetMetadata {
        option::is_some(&borrow_caps(asset).mint)
    }

    public fun caps_contain_freeze<T: key>(asset: &Object<T>): bool acquires FungibleAssetMetadata {
        option::is_some(&borrow_caps(asset).freeze)
    }

    public fun caps_contain_burn<T: key>(asset: &Object<T>): bool acquires FungibleAssetMetadata {
        option::is_some(&borrow_caps(asset).burn)
    }


    public fun borrow_mint_from_caps<T: key>(
        owner: &signer,
        asset: &Object<T>
    ): &MintCap acquires FungibleAssetMetadata {
        assert!(is_owner(*asset, address_of(owner)), error::permission_denied(ENOT_OWNER));
        let mint_cap = &borrow_caps(asset).mint;
        assert!(option::is_some(mint_cap), error::not_found(EMINT_CAP));
        option::borrow(mint_cap)
    }

    public fun borrow_freeze_from_caps<T: key>(
        owner: &signer,
        asset: &Object<T>
    ): &FreezeCap acquires FungibleAssetMetadata {
        assert!(is_owner(*asset, address_of(owner)), error::permission_denied(ENOT_OWNER));
        let freeze_cap = &borrow_caps(asset).freeze;
        assert!(option::is_some(freeze_cap), error::not_found(EFREEZE_CAP));
        option::borrow(&borrow_caps(asset).freeze)
    }

    public fun borrow_burn_from_caps<T: key>(
        owner: &signer,
        asset: &Object<T>
    ): &BurnCap acquires FungibleAssetMetadata {
        assert!(is_owner(*asset, address_of(owner)), error::permission_denied(ENOT_OWNER));
        let burn_cap = &borrow_caps(asset).freeze;
        assert!(option::is_some(burn_cap), error::not_found(EBURN_CAP));
        option::borrow(&borrow_caps(asset).burn)
    }

    public fun get_mint_from_caps<T: key>(owner: &signer, asset: &Object<T>): MintCap acquires FungibleAssetMetadata {
        let mint_cap = &mut borrow_caps_mut(owner, asset).mint;
        assert!(option::is_some(mint_cap), error::not_found(EMINT_CAP));
        option::extract(mint_cap)
    }

    public fun get_freeze_from_caps<T: key>(
        owner: &signer,
        asset: &Object<T>
    ): FreezeCap acquires FungibleAssetMetadata {
        let freeze_cap = &mut borrow_caps_mut(owner, asset).freeze;
        assert!(option::is_some(freeze_cap), error::not_found(EFREEZE_CAP));
        option::extract(freeze_cap)
    }

    public fun get_burn_from_caps<T: key>(owner: &signer, asset: &Object<T>): BurnCap acquires FungibleAssetMetadata {
        let burn_cap = &mut borrow_caps_mut(owner, asset).burn;
        assert!(option::is_some(burn_cap), error::not_found(EBURN_CAP));
        option::extract(burn_cap)
    }

    public fun put_mint_to_caps<T: key>(
        owner: &signer,
        asset: &Object<T>,
        cap: MintCap
    ) acquires FungibleAssetMetadata {
        assert_mint_cap_and_asset_match(&cap, asset);
        let mint_cap = &mut borrow_caps_mut(owner, asset).mint;
        assert!(option::is_none(mint_cap), error::already_exists(EMINT_CAP));
        option::fill(mint_cap, cap);
    }

    public fun put_freeze_to_caps<T: key>(
        owner: &signer,
        asset: &Object<T>,
        cap: FreezeCap
    ) acquires FungibleAssetMetadata {
        assert_freeze_cap_and_asset_match(&cap, asset);
        let freeze_cap = &mut borrow_caps_mut(owner, asset).freeze;
        assert!(option::is_none(freeze_cap), error::already_exists(EFREEZE_CAP));
        option::fill(freeze_cap, cap);
    }

    public fun put_burn_to_caps<T: key>(
        owner: &signer,
        asset: &Object<T>,
        cap: BurnCap
    ) acquires FungibleAssetMetadata {
        assert_burn_cap_and_asset_match(&cap, asset);
        let burn_cap = &mut borrow_caps_mut(owner, asset).burn;
        assert!(option::is_none(burn_cap), error::already_exists(EBURN_CAP));
        option::fill(burn_cap, cap);
    }

    public fun assert_mint_cap_and_asset_match<T: key>(cap: &MintCap, asset: &Object<T>) {
        assert!(cap.asset_addr == object_address(asset), error::invalid_argument(EMINT_CAP));
    }

    public fun assert_freeze_cap_and_asset_match<T: key>(cap: &FreezeCap, asset: &Object<T>) {
        assert!(cap.asset_addr == object_address(asset), error::invalid_argument(EFREEZE_CAP));
    }

    public fun assert_burn_cap_and_asset_match<T: key>(cap: &BurnCap, asset: &Object<T>) {
        assert!(cap.asset_addr == object_address(asset), error::invalid_argument(EMINT_CAP));
    }
}
