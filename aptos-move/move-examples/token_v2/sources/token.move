/// This defines an object-based Token. The key differentiating features from the Aptos standard
/// token are:
/// * Decouple token ownership from token data.
/// * Explicit data model for token metadata via adjacent resources
/// * Extensible framework for tokens
///
/// TODO:
/// * Provide functions for mutability -- the refability model seems to heavy for mutations, so
///   probably keep the existing model
/// * Consider adding an optional source name if name is mutated, since the objects address depends
///   on the name...
/// * Update ObjectId to be an acceptable param to move
module token_v2::token {
    use std::error;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use std::signer;
    use token_v2::refs;

    /// The token does or does not exist
    const ETOKEN: u64 = 1;
    /// The provided signer is not the creator
    const ENOT_CREATOR: u64 = 2;
    /// Attempted to mutate an immutable field
    const EFIELD_NOT_MUTABLE: u64 = 3;
    /// The token indexer existence.
    const ETOKEN_INDEXER: u64 = 4;
    /// The existence of a specific token index in the token indexer.
    const ETOKEN_INDEX: u64 = 5;
    /// The provided signer is not the owner
    const ENOT_OWNER: u64 = 6;
    /// The existence of extend_ref
    const EEXTEND_REF: u64 = 9;
    /// The existence of transfer_ref
    const ETRANSFER_REF: u64 = 10;
    /// The existence of extend_ref
    const EDELETE_REF: u64 = 11;
    /// The token is not an NFT
    const ENOT_NFT: u64 = 12;

    use aptos_framework::object::{Self, ConstructorRef, Object, create_object_from_account, object_from_extend_ref, TransferRef, object_from_transfer_ref, object_address, object_from_delete_ref, is_owner, ExtendRef, DeleteRef, generate_signer_for_extending};

    use aptos_std::smart_table::SmartTable;
    use token_v2::common::{Royalty, assert_valid_name, init_fungible_asset_metadata, new_supply};
    use aptos_std::smart_table;
    use token_v2::collection::{Collection, get_collection_object};
    use token_v2::common;
    use token_v2::collection;
    use token_v2::refs::{Refs, refs_contain_extend, extract_extend_from_refs, add_extend_to_refs, refs_contain_transfer, extract_transfer_from_refs, add_transfer_to_refs, refs_contain_delete, extract_delete_from_refs, add_delete_to_refs};

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Represents the common fields to all tokens.
    struct Token has key {
        /// An optional categorization of similar token, there are no constraints on collections.
        collection: Option<Object<Collection>>,
        /// The original creator of this token.
        creator: address,
        /// A brief description of the token.
        description: String,
        /// Determines which fields are mutable.
        mutability_config: MutabilityConfig,
        /// The name of the token, which should be unique within the collection; the length of name
        /// should be smaller than 128, characters, eg: "Aptos Animal #1234"
        name: String,
        /// The Uniform Resource Identifier (uri) pointing to the JSON file stored in off-chain
        /// storage; the URL length will likely need a maximum any suggestions?
        uri: String,
    }

    /// This config specifies which fields in the TokenData are mutable
    struct MutabilityConfig has copy, drop, store {
        description: bool,
        name: bool,
        uri: bool,
    }

    struct TokenIndexer has key {
        index: SmartTable<String, Refs>
    }

    struct OwnerRefs has key {
        refs: Refs,
    }

    /// Create a token object and return its `ConstructurRef, which could be used to generate 3 storable object Refs for
    /// customized object control logic. It is not for general use cases.
    /// Drop the returned `ConstructorRef` unless you know what you are doing.
    public fun create_token(
        creator: &signer,
        collection_name: Option<String>,
        description: String,
        mutability_config: MutabilityConfig,
        name: String,
        royalty: Option<Royalty>,
        uri: String,
        creator_enabled_refs: vector<bool>, // extend, transfer, delete
        owner_enabled_refs: vector<bool>, // extend, transfer, delete
    ): ConstructorRef acquires TokenIndexer {
        let creator_ref = create_object_from_account(creator);
        let object_signer = object::generate_signer(&creator_ref);

        let creator_address = signer::address_of(creator);
        let token_index_key = generate_token_index_key(collection_name, name);
        let collection = if (option::is_some(&collection_name)) {
            let col_name = option::destroy_some(collection_name);
            collection::increment_supply(creator_address, col_name);
            option::some(get_collection_object(creator_address, col_name))
        } else {
            option::none()
        };

        // Put the refs into creator
        let creator_refs = refs::new_refs_from_constructor_ref(&creator_ref, creator_enabled_refs);
        assert!(exists<TokenIndexer>(creator_address), error::not_found(ETOKEN_INDEXER));
        let token_indexer = &mut borrow_global_mut<TokenIndexer>(creator_address).index;
        assert!(!smart_table::contains(token_indexer, name), error::already_exists(ETOKEN_INDEX));
        smart_table::add(token_indexer, token_index_key, creator_refs);

        let owner_refs = OwnerRefs {
            refs: refs::new_refs_from_constructor_ref(&creator_ref, owner_enabled_refs)
        };

        let token = Token {
            collection,
            creator: creator_address,
            description,
            mutability_config,
            name,
            uri,
        };

        // All the resources in this object at token layer.
        move_to(&object_signer, token);
        move_to(&object_signer, owner_refs);
        if (option::is_some(&royalty)) {
            common::init_royalty(&object_signer, option::extract(&mut royalty))
        };
        creator_ref
    }

    /// Indicate whether this `Token` object is an NFT or the asset of fungible tokens.
    public fun is_nft(token_obj: Object<Token>): bool {
        !common::fungible_asset_metadata_exists(&token_obj)
    }

    /// Convert a NFT into an asset of fungible token. After calling this, `mint_fungible_coin` is allowed to call.
    /// After this call, owner of asset can call `coin::mint_by_asset_owner` to mint coins.
    public fun convert_nft_to_ft(
        token_obj_extend_ref: &ExtendRef,
        token_obj: &Object<Token>,
        max_supply: Option<u64>,
        cap_flags: vector<bool>
    ) {
        common::assert_fungible_asset_metadata_not_exists(token_obj);
        let token_obj_signer = generate_signer_for_extending(token_obj_extend_ref);
        let supply = new_supply(max_supply);
        init_fungible_asset_metadata(&token_obj_signer, supply, cap_flags);
    }

    /// As a base of fungible token, if all the issued fungible tokens are burned, it can be converted back to a NFT.
    /// whether we should only allow token owner to convert?
    public fun convert_ft_into_nft(owner: &signer, token_obj: &Object<Token>) {
        common::remove_fungible_asset_metadata(owner, token_obj);
    }

    inline fun generate_token_index_key(collection_name: Option<String>, token_name: String): String {
        assert_valid_name(&token_name);
        if (option::is_some(&collection_name)) {
            let name = option::destroy_some(collection_name);
            assert_valid_name(&name);
            string::append_utf8(&mut name, vector[0x0]);
            string::append(&mut name, token_name);
            name
        } else {
            token_name
        }
    }

    inline fun borrow_creator_refs(token_obj: Object<Token>): &Refs acquires Token, TokenIndexer {
        let token_addr = verify(&token_obj);
        let token = borrow_global<Token>(token_addr);
        let collection_name = option::map(token.collection, |obj| collection::name(obj));
        let token_index_key = generate_token_index_key(collection_name, token.name);
        let token_index = &mut borrow_global<TokenIndexer>(token.creator).index;
        assert!(smart_table::contains(token_index, token_index_key), error::not_found(ETOKEN_INDEX));
        smart_table::borrow(token_index, token_index_key)
    }

    inline fun borrow_creator_refs_mut(token_obj: Object<Token>): &mut Refs acquires Token, TokenIndexer {
        let token_addr = verify(&token_obj);
        let token = borrow_global<Token>(token_addr);
        let collection_name = option::map(token.collection, |obj| collection::name(obj));
        let token_index_key = generate_token_index_key(collection_name, token.name);
        let token_index = &mut borrow_global_mut<TokenIndexer>(token.creator).index;
        assert!(smart_table::contains(token_index, token_index_key), error::not_found(ETOKEN_INDEX));
        smart_table::borrow_mut(token_index, token_index_key)
    }

    fun remove_creator_refs(token_obj: Object<Token>): Refs acquires Token, TokenIndexer {
        let token_addr = verify(&token_obj);
        let token = borrow_global<Token>(token_addr);
        let collection_name = option::map(token.collection, |obj| {
            let name = collection::name(obj);
            // Removing creator_refs means deleting the token so if collection exists, we have to decrement collection
            // supply.
            collection::decrement_supply(token.creator, name);
            name
        });
        let token_index_key = generate_token_index_key(collection_name, token.name);
        let token_index = &mut borrow_global_mut<TokenIndexer>(token.creator).index;
        assert!(smart_table::contains(token_index, token_index_key), error::not_found(ETOKEN_INDEX));
        smart_table::remove(token_index, token_index_key)
    }

    inline fun assert_owner(owner: &signer, token_obj: Object<Token>) {
        assert!(is_owner(token_obj, signer::address_of(owner)), error::permission_denied(ENOT_OWNER));
    }

    inline fun assert_creator(creator: &signer, token_obj: Object<Token>) acquires Token {
        let token_addr = verify(&token_obj);
        let token = borrow_global<Token>(token_addr);
        assert!(token.creator == signer::address_of(creator), error::permission_denied(ENOT_CREATOR));
    }

    inline fun assert_nft(token_obj: Object<Token>) {
        assert!(is_nft(token_obj), error::permission_denied(ENOT_NFT));
    }

    /// ================================================================================================================
    /// Check, Get, Put TransferRef
    /// ================================================================================================================
    public fun check_extend_ref_in_owner_refs(token_obj: Object<Token>): bool acquires OwnerRefs {
        let owner_refs = &borrow_global<OwnerRefs>(object_address(&token_obj)).refs;
        refs_contain_extend(owner_refs)
    }

    public fun get_extend_ref_from_owner_refs(owner: &signer, token_obj: Object<Token>): ExtendRef acquires OwnerRefs {
        assert_owner(owner, token_obj);
        let owner_refs = &mut borrow_global_mut<OwnerRefs>(object_address(&token_obj)).refs;
        assert!(refs_contain_extend(owner_refs), error::not_found(EEXTEND_REF));
        extract_extend_from_refs(owner_refs)
    }

    public fun put_extend_ref_to_owner_refs(
        owner: &signer,
        token_obj: Object<Token>,
        extend_ref: ExtendRef
    ) acquires OwnerRefs {
        assert_owner(owner, token_obj);
        let owner_refs = &mut borrow_global_mut<OwnerRefs>(object_address(&token_obj)).refs;
        add_extend_to_refs(owner_refs, extend_ref);
    }

    public fun check_extend_ref_in_creator_refs(token_obj: Object<Token>): bool acquires Token, TokenIndexer {
        let creator_refs = borrow_creator_refs(token_obj);
        refs_contain_extend(creator_refs)
    }

    public fun get_extend_ref_from_creator_refs(
        creator: &signer,
        token_obj: Object<Token>
    ): ExtendRef acquires Token, TokenIndexer {
        assert_creator(creator, token_obj);
        let creator_refs = borrow_creator_refs_mut(token_obj);
        assert!(refs_contain_extend(creator_refs), error::not_found(EEXTEND_REF));
        extract_extend_from_refs(creator_refs)
    }

    public fun put_extend_ref_to_creator_refs(
        creator: &signer,
        token_obj: Object<Token>,
        extend_ref: ExtendRef
    ) acquires Token, TokenIndexer {
        assert_creator(creator, token_obj);
        let creator_refs = borrow_creator_refs_mut(token_obj);
        add_extend_to_refs(creator_refs, extend_ref);
    }

    /// ================================================================================================================
    /// Check, Get, Put TransferRef
    /// ================================================================================================================
    public fun check_transfer_ref_in_owner_refs(token_obj: Object<Token>): bool acquires OwnerRefs {
        let owner_refs = &borrow_global<OwnerRefs>(object_address(&token_obj)).refs;
        refs_contain_transfer(owner_refs)
    }

    public fun get_transfer_ref_from_owner_refs(
        owner: &signer,
        token_obj: Object<Token>
    ): TransferRef acquires OwnerRefs {
        assert_owner(owner, token_obj);
        let owner_refs = &mut borrow_global_mut<OwnerRefs>(object_address(&token_obj)).refs;
        assert!(refs_contain_transfer(owner_refs), error::not_found(ETRANSFER_REF));
        extract_transfer_from_refs(owner_refs)
    }

    public fun put_transfer_ref_to_owner_refs(
        owner: &signer,
        token_obj: Object<Token>,
        transfer_ref: TransferRef
    ) acquires OwnerRefs {
        assert_owner(owner, token_obj);
        let owner_refs = &mut borrow_global_mut<OwnerRefs>(object_address(&token_obj)).refs;
        add_transfer_to_refs(owner_refs, transfer_ref);
    }

    public fun check_transfer_ref_in_creator_refs(token_obj: Object<Token>): bool acquires Token, TokenIndexer {
        let creator_refs = borrow_creator_refs(token_obj);
        refs_contain_transfer(creator_refs)
    }

    public fun get_transfer_ref_from_creator_refs(
        creator: &signer,
        token_obj: Object<Token>
    ): TransferRef acquires Token, TokenIndexer {
        assert_creator(creator, token_obj);
        let creator_refs = borrow_creator_refs_mut(token_obj);

        assert!(refs_contain_transfer(creator_refs), error::not_found(ETRANSFER_REF));
        extract_transfer_from_refs(creator_refs)
    }

    public fun put_transfer_ref_to_creator_refs(
        creator: &signer,
        token_obj: Object<Token>,
        transfer_ref: TransferRef
    ) acquires Token, TokenIndexer {
        assert_creator(creator, token_obj);
        let creator_refs = borrow_creator_refs_mut(token_obj);
        add_transfer_to_refs(creator_refs, transfer_ref);
    }


    /// ================================================================================================================
    /// Check, Use, Put DeleteRef
    /// ================================================================================================================
    public fun check_delete_ref_in_owner_refs(token_obj: Object<Token>): bool acquires OwnerRefs {
        let owner_refs = &borrow_global<OwnerRefs>(object_address(&token_obj)).refs;
        refs_contain_delete(owner_refs)
    }

    public entry fun delete_token_from_owner_refs(
        owner: &signer,
        token_obj: Object<Token>
    ) acquires OwnerRefs, Token, TokenIndexer {
        // Deleting a token as a base of fungible asset is not allowed.
        assert_nft(token_obj);
        assert_owner(owner, token_obj);

        let token_addr = verify(&token_obj);
        let owner_refs = &mut borrow_global_mut<OwnerRefs>(token_addr).refs;
        assert!(refs_contain_delete(owner_refs), error::not_found(EDELETE_REF));
        let delete_ref = extract_delete_from_refs(owner_refs);

        remove_creator_refs(token_obj);

        // Remove token resources
        move_from<Token>(token_addr);
        move_from<OwnerRefs>(token_addr);
        if (common::exists_royalty(token_addr)) {
            common::remove_royalty(token_addr);
        };
        object::delete(delete_ref);
    }

    public fun put_delete_ref_to_owner_refs(
        owner: &signer,
        token_obj: Object<Token>,
        delete_ref: DeleteRef
    ) acquires OwnerRefs {
        assert_owner(owner, token_obj);
        let owner_refs = &mut borrow_global_mut<OwnerRefs>(object_address(&token_obj)).refs;
        add_delete_to_refs(owner_refs, delete_ref);
    }

    public fun check_delete_ref_in_creator_refs(token_obj: Object<Token>): bool acquires Token, TokenIndexer {
        let creator_refs = borrow_creator_refs(token_obj);
        refs_contain_delete(creator_refs)
    }

    public entry fun delete_token_from_creator_refs(
        creator: &signer,
        token_obj: Object<Token>
    ) acquires Token, TokenIndexer, OwnerRefs {
        // Deleting a token as a base of fungible asset is not allowed.
        assert_nft(token_obj);
        assert_creator(creator, token_obj);

        let token_addr = verify(&token_obj);
        // remove creator refs from token index
        let creator_refs = remove_creator_refs(token_obj);
        assert!(refs_contain_delete(&creator_refs), error::not_found(EDELETE_REF));
        let delete_ref = extract_delete_from_refs(&mut creator_refs);

        // Remove token resources
        move_from<Token>(token_addr);
        move_from<OwnerRefs>(token_addr);
        if (common::exists_royalty(token_addr)) {
            common::remove_royalty(token_addr);
        };
        object::delete(delete_ref);
    }

    public fun put_delete_ref_to_creator_refs(
        creator: &signer,
        token_obj: Object<Token>,
        delete_ref: DeleteRef
    ) acquires Token, TokenIndexer {
        assert_creator(creator, token_obj);
        let creator_refs = borrow_creator_refs_mut(token_obj);
        add_delete_to_refs(creator_refs, delete_ref);
    }

    public fun create_mutability_config(description: bool, name: bool, uri: bool): MutabilityConfig {
        MutabilityConfig { description, name, uri }
    }

    /// Simple token creation that generates a token and deposits it into the creators object store.
    public entry fun mint_token(
        creator: &signer,
        collection: Option<String>,
        description: String,
        name: String,
        uri: String,
        mutable_description: bool,
        mutable_name: bool,
        mutable_uri: bool,
        enable_royalty: bool,
        royalty_percentage: u8,
        royalty_payee_address: address,
        creator_enabled_refs: vector<bool>, // extend, transfer, delete
        owner_enabled_refs: vector<bool>, // extend, transfer, delete
    ): ConstructorRef acquires TokenIndexer {
        let mutability_config = create_mutability_config(
            mutable_description,
            mutable_name,
            mutable_uri,
        );

        let royalty = if (enable_royalty) {
            option::some(common::create_royalty(
                royalty_percentage,
                royalty_payee_address,
            ))
        } else {
            option::none()
        };

        create_token(
            creator,
            collection,
            description,
            mutability_config,
            name,
            royalty,
            uri,
            creator_enabled_refs,
            owner_enabled_refs,
        )
    }

    // Accessors
    inline fun verify<T: key>(token: &Object<T>): address {
        let token_address = object::object_address(token);
        assert!(
            exists<Token>(token_address),
            error::not_found(ETOKEN),
        );
        token_address
    }

    public fun creator<T: key>(token: Object<T>): address acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).creator
    }

    public fun collection<T: key>(token: Object<T>): Option<Object<Collection>> acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).collection
    }

    public fun description<T: key>(token: Object<T>): String acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).description
    }

    public fun is_description_mutable<T: key>(token: Object<T>): bool acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).mutability_config.description
    }

    public fun is_name_mutable<T: key>(token: Object<T>): bool acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).mutability_config.name
    }

    public fun is_uri_mutable<T: key>(token: Object<T>): bool acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).mutability_config.uri
    }

    public fun name<T: key>(token: Object<T>): String acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).name
    }

    public fun uri<T: key>(token: Object<T>): String acquires Token {
        let token_address = verify(&token);
        borrow_global<Token>(token_address).uri
    }

    // Mutators
    public fun set_description<T: key>(
        creator: &signer,
        token: Object<T>,
        description: String,
    ) acquires Token {
        let token_address = verify(&token);
        let token = borrow_global_mut<Token>(token_address);
        assert!(
            token.creator == signer::address_of(creator),
            error::permission_denied(ENOT_CREATOR),
        );
        assert!(
            token.mutability_config.description,
            error::permission_denied(EFIELD_NOT_MUTABLE),
        );
        token.description = description;
    }

    public fun set_name<T: key>(
        creator: &signer,
        token: Object<T>,
        name: String,
    ) acquires Token {
        let token_address = verify(&token);
        let token = borrow_global_mut<Token>(token_address);
        assert!(
            token.creator == signer::address_of(creator),
            error::permission_denied(ENOT_CREATOR),
        );
        assert!(
            token.mutability_config.name,
            error::permission_denied(EFIELD_NOT_MUTABLE),
        );

        token.name = name;
    }

    public fun set_uri<T: key>(
        creator: &signer,
        token: Object<T>,
        uri: String,
    ) acquires Token {
        let token_address = verify(&token);
        let token = borrow_global_mut<Token>(token_address);
        assert!(
            token.creator == signer::address_of(creator),
            error::permission_denied(ENOT_CREATOR),
        );
        assert!(
            token.mutability_config.uri,
            error::permission_denied(EFIELD_NOT_MUTABLE),
        );
        token.uri = uri;
    }
}
