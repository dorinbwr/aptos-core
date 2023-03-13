/// PropertyMap provides generic metadata support for AptosToken. It is a  specialization of
/// SimpleMap that enforces strict typing with minimal storage use by using constant u64 to
/// represent types and storing values in bcs format.
module token_objects::property_map {
    use std::bcs;
    use std::vector;
    use std::error;
    use std::string::{Self, String};
    use aptos_std::from_bcs;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::type_info;

    use aptos_framework::object::{Self, ConstructorRef, Object};

    // Errors

    /// The property key already exists
    const EKEY_AREADY_EXIST_IN_PROPERTY_MAP: u64 = 1;
    /// The number of property exceeds the limit
    const EPROPERTY_NUMBER_EXCEEDS_LIMIT: u64 = 2;
    /// Property key and value counts do not match
    const EKEY_VALUE_COUNT_MISMATCH: u64 = 3;
    /// Property key and type count do not match
    const EKEY_TYPE_COUNT_MISMATCH: u64 = 4;
    /// Property type does not match
    const ETYPE_MISMATCH: u64 = 5;
    /// The name (key) of the property is too long
    const EPROPERTY_MAP_NAME_TOO_LONG: u64 = 6;
    /// The property map does not exist within global storage
    const EPROPERTY_MAP_DOES_NOT_EXIST: u64 = 7;
    /// Invalid type specified
    const ETYPE_INVALID: u64 = 8;

    // Constants
    const MAX_PROPERTY_MAP_SIZE: u64 = 1000;
    const MAX_PROPERTY_NAME_LENGTH: u64 = 128;

    const BOOL: u8 = 0;
    const U8: u8 = 1;
    const U16: u8 = 2;
    const U32: u8 = 3;
    const U64: u8 = 4;
    const U128: u8 = 5;
    const U256: u8 = 6;
    const ADDRESS: u8 = 7;
    const BYTE_VECTOR: u8 = 8;
    const STRING: u8 = 9;

    // Structs

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct PropertyMap has key {
        inner: SimpleMap<String, PropertyValue>,
    }

    struct PropertyValue has drop, store {
        type: u8,
        value: vector<u8>,
    }

    struct MutatorRef has drop, store {
        self: address,
    }

    public fun init(ref: &ConstructorRef, container: PropertyMap) {
        let signer = object::generate_signer(ref);
        move_to(&signer, container);
    }

    /// Helper for external entry functions to produce a valid container for property values.
    public fun prepare_input(
        keys: vector<String>,
        types: vector<String>,
        values: vector<vector<u8>>,
    ): PropertyMap {
        let length = vector::length(&keys);
        assert!(length <= MAX_PROPERTY_MAP_SIZE, error::invalid_argument(EPROPERTY_NUMBER_EXCEEDS_LIMIT));
        assert!(length == vector::length(&values), error::invalid_argument(EKEY_VALUE_COUNT_MISMATCH));
        assert!(length == vector::length(&types), error::invalid_argument(EKEY_TYPE_COUNT_MISMATCH));

        let container = simple_map::create<String, PropertyValue>();
        while (!vector::is_empty(&keys)) {
            let key = vector::pop_back(&mut keys);
            assert!(
                string::length(&key) <= MAX_PROPERTY_NAME_LENGTH,
                error::invalid_argument(EPROPERTY_MAP_NAME_TOO_LONG),
            );

            let value = vector::pop_back(&mut values);
            let type = vector::pop_back(&mut types);

            let new_type = to_internal_type(type);
            validate_type(new_type, value);

            simple_map::add(&mut container, key, PropertyValue { value, type: new_type });
        };

        PropertyMap { inner: container }
    }

    inline fun to_external_type(type: u8): String {
        if (type == BOOL) {
            string::utf8(b"bool")
        } else if (type == U8) {
            string::utf8(b"u8")
        } else if (type == U16) {
            string::utf8(b"u16")
        } else if (type == U32) {
            string::utf8(b"u32")
        } else if (type == U64) {
            string::utf8(b"u64")
        } else if (type == U128) {
            string::utf8(b"u128")
        } else if (type == U256) {
            string::utf8(b"u256")
        } else if (type == ADDRESS) {
            string::utf8(b"address")
        } else if (type == BYTE_VECTOR) {
            string::utf8(b"bytes")
        } else if (type == STRING) {
            string::utf8(b"string")
        } else {
            abort(error::invalid_argument(ETYPE_INVALID))
        }
    }

    inline fun to_internal_type(type: String): u8 {
        if (type == string::utf8(b"bool")) {
            BOOL
        } else if (type == string::utf8(b"u8")) {
            U8
        } else if (type == string::utf8(b"u16")) {
            U16
        } else if (type == string::utf8(b"u32")) {
            U32
        } else if (type == string::utf8(b"u64")) {
            U64
        } else if (type == string::utf8(b"u128")) {
            U128
        } else if (type == string::utf8(b"u256")) {
            U256
        } else if (type == string::utf8(b"address")) {
            ADDRESS
        } else if (type == string::utf8(b"bytes")) {
            BYTE_VECTOR
        } else if (type == string::utf8(b"string")) {
            STRING
        } else {
            abort(error::invalid_argument(ETYPE_INVALID))
        }
    }

    inline fun type_info_to_internal_type<T>(): u8 {
        let type = type_info::type_name<T>();
        if (type == string::utf8(b"bool")) {
            BOOL
        } else if (type == string::utf8(b"u8")) {
            U8
        } else if (type == string::utf8(b"u16")) {
            U16
        } else if (type == string::utf8(b"u32")) {
            U32
        } else if (type == string::utf8(b"u64")) {
            U64
        } else if (type == string::utf8(b"u128")) {
            U128
        } else if (type == string::utf8(b"u256")) {
            U256
        } else if (type == string::utf8(b"address")) {
            ADDRESS
        } else if (type == string::utf8(b"vector<u8>")) {
            BYTE_VECTOR
        } else if (type == string::utf8(b"0x1::string::String")) {
            STRING
        } else {
            abort(error::invalid_argument(ETYPE_INVALID))
        }
    }

    inline fun validate_type(type: u8, value: vector<u8>) {
        if (type == BOOL) {
            from_bcs::to_bool(value);
        } else if (type == U8) {
            from_bcs::to_u8(value);
        } else if (type == U16) {
            from_bcs::to_u16(value);
        } else if (type == U32) {
            from_bcs::to_u32(value);
        } else if (type == U64) {
            from_bcs::to_u64(value);
        } else if (type == U128) {
            from_bcs::to_u128(value);
        } else if (type == U256) {
            from_bcs::to_u256(value);
        } else if (type == ADDRESS) {
            from_bcs::to_address(value);
        } else if (type == BYTE_VECTOR) {
            // nothing to validate...
        } else if (type == STRING) {
            from_bcs::to_string(value);
        } else {
            abort(error::invalid_argument(ETYPE_INVALID))
        };
    }

    public fun generate_mutator_ref(ref: &ConstructorRef): MutatorRef {
        MutatorRef { self: object::address_from_constructor_ref(ref) }
    }

    // Accessors

    public fun contains_key<T: key>(object: &Object<T>, key: &String): bool acquires PropertyMap {
        assert!(
            exists<PropertyMap>(object::object_address(object)),
            error::not_found(EPROPERTY_MAP_DOES_NOT_EXIST),
        );
        let property_map = borrow_global<PropertyMap>(object::object_address(object));
        simple_map::contains_key(&property_map.inner, key)
    }

    public fun length<T: key>(object: &Object<T>): u64 acquires PropertyMap {
        assert!(
            exists<PropertyMap>(object::object_address(object)),
            error::not_found(EPROPERTY_MAP_DOES_NOT_EXIST),
        );
        let property_map = borrow_global<PropertyMap>(object::object_address(object));
        simple_map::length(&property_map.inner)
    }

    public fun read<T: key>(object: &Object<T>, key: &String): (String, vector<u8>) acquires PropertyMap {
        assert!(
            exists<PropertyMap>(object::object_address(object)),
            error::not_found(EPROPERTY_MAP_DOES_NOT_EXIST),
        );
        let property_map = borrow_global<PropertyMap>(object::object_address(object));
        let property_value = simple_map::borrow(&property_map.inner, key);
        let new_type = to_external_type(property_value.type);
        (new_type, property_value.value)
    }

    public fun read_bool<T: key>(object: &Object<T>, key: &String): bool acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"bool"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_bool(value)
    }

    public fun read_u8<T: key>(object: &Object<T>, key: &String): u8 acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"u8"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_u8(value)
    }

    public fun read_u16<T: key>(object: &Object<T>, key: &String): u16 acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"u16"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_u16(value)
    }

    public fun read_u32<T: key>(object: &Object<T>, key: &String): u32 acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"u32"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_u32(value)
    }

    public fun read_u64<T: key>(object: &Object<T>, key: &String): u64 acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"u64"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_u64(value)
    }

    public fun read_u128<T: key>(object: &Object<T>, key: &String): u128 acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"u128"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_u128(value)
    }

    public fun read_u256<T: key>(object: &Object<T>, key: &String): u256 acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"u256"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_u256(value)
    }

    public fun read_address<T: key>(object: &Object<T>, key: &String): address acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"address"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_address(value)
    }

    public fun read_bytes<T: key>(object: &Object<T>, key: &String): vector<u8>acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"bytes"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_bytes(value)
    }

    public fun read_string<T: key>(object: &Object<T>, key: &String): String acquires PropertyMap {
        let (type, value) = read(object, key);
        assert!(
            type == string::utf8(b"string"),
            error::invalid_argument(ETYPE_INVALID),
        );
        from_bcs::to_string(value)
    }

    // Mutators

    public fun add(ref: &MutatorRef, key: String, type: String, value: vector<u8>) acquires PropertyMap {
        let new_type = to_internal_type(type);
        validate_type(new_type, value);
        add_internal(ref, key, new_type, value);
    }

    public fun add_typed<T: drop>(ref: &MutatorRef, key: String, value: T) acquires PropertyMap {
        let type = type_info_to_internal_type<T>();
        add_internal(ref, key, type, bcs::to_bytes(&value));
    }

    fun add_internal(ref: &MutatorRef, key: String, type: u8, value: vector<u8>) acquires PropertyMap {
        assert!(exists<PropertyMap>(ref.self), error::not_found(EPROPERTY_MAP_DOES_NOT_EXIST));
        let property_map = borrow_global_mut<PropertyMap>(ref.self);
        simple_map::add(&mut property_map.inner, key, PropertyValue { type, value });
    }

    public fun update(ref: &MutatorRef, key: &String, type: String, value: vector<u8>) acquires PropertyMap {
        let new_type = to_internal_type(type);
        validate_type(new_type, value);
        update_internal(ref, key, new_type, value);
    }

    public fun update_typed<T: drop>(ref: &MutatorRef, key: &String, value: T) acquires PropertyMap {
        let type = type_info_to_internal_type<T>();
        update_internal(ref, key, type, bcs::to_bytes(&value));
    }

    fun update_internal(ref: &MutatorRef, key: &String, type: u8, value: vector<u8>) acquires PropertyMap {
        assert!(exists<PropertyMap>(ref.self), error::not_found(EPROPERTY_MAP_DOES_NOT_EXIST));
        let property_map = borrow_global_mut<PropertyMap>(ref.self);
        let old_value = simple_map::borrow_mut(&mut property_map.inner, key);
        *old_value = PropertyValue { type, value };
    }

    public fun remove(ref: &MutatorRef, key: &String) acquires PropertyMap {
        assert!(exists<PropertyMap>(ref.self), error::not_found(EPROPERTY_MAP_DOES_NOT_EXIST));
        let property_map = borrow_global_mut<PropertyMap>(ref.self);
        simple_map::remove(&mut property_map.inner, key);
    }

    // Tests

    #[test(creator = @0x123)]
    fun test_end_to_end(creator: &signer) acquires PropertyMap {
        let constructor_ref = object::create_named_object(creator, b"");
        let object = object::object_from_constructor_ref<object::ObjectCore>(&constructor_ref);

        let input = prepare_input(
            vector[
                string::utf8(b"bool"),
                string::utf8(b"u8"),
                string::utf8(b"u16"),
                string::utf8(b"u32"),
                string::utf8(b"u64"),
                string::utf8(b"u128"),
                string::utf8(b"u256"),
                string::utf8(b"bytes"),
                string::utf8(b"string"),
            ],
            vector[
                string::utf8(b"bool"),
                string::utf8(b"u8"),
                string::utf8(b"u16"),
                string::utf8(b"u32"),
                string::utf8(b"u64"),
                string::utf8(b"u128"),
                string::utf8(b"u256"),
                string::utf8(b"bytes"),
                string::utf8(b"string"),
            ],
            vector[
                bcs::to_bytes<bool>(&true),
                bcs::to_bytes<u8>(&0x12),
                bcs::to_bytes<u16>(&0x1234),
                bcs::to_bytes<u32>(&0x12345678),
                bcs::to_bytes<u64>(&0x1234567812345678),
                bcs::to_bytes<u128>(&0x12345678123456781234567812345678),
                bcs::to_bytes<u256>(&0x1234567812345678123456781234567812345678123456781234567812345678),
                bcs::to_bytes<vector<u8>>(&vector[0x01]),
                bcs::to_bytes<String>(&string::utf8(b"a")),
            ],
        );
        init(&constructor_ref, input);
        let mutator = generate_mutator_ref(&constructor_ref);

        assert!(read_bool(&object, &string::utf8(b"bool")), 0);
        assert!(read_u8(&object, &string::utf8(b"u8")) == 0x12, 1);
        assert!(read_u16(&object, &string::utf8(b"u16")) == 0x1234, 2);
        assert!(read_u32(&object, &string::utf8(b"u32")) == 0x12345678, 3);
        assert!(read_u64(&object, &string::utf8(b"u64")) == 0x1234567812345678, 4);
        assert!(read_u128(&object, &string::utf8(b"u128")) == 0x12345678123456781234567812345678, 5);
        assert!(read_u256(&object, &string::utf8(b"u256")) == 0x1234567812345678123456781234567812345678123456781234567812345678, 6);
        assert!(read_bytes(&object, &string::utf8(b"bytes")) == vector[0x01], 7);
        assert!(read_string(&object, &string::utf8(b"string")) == string::utf8(b"a"), 8);

        assert!(length(&object) == 9, 9);

        update_typed<bool>(&mutator, &string::utf8(b"bool"), false);
        update_typed<u8>(&mutator, &string::utf8(b"u8"), 0x21);
        update_typed<u16>(&mutator, &string::utf8(b"u16"), 0x22);
        update_typed<u32>(&mutator, &string::utf8(b"u32"), 0x23);
        update_typed<u64>(&mutator, &string::utf8(b"u64"), 0x24);
        update_typed<u128>(&mutator, &string::utf8(b"u128"), 0x25);
        update_typed<u256>(&mutator, &string::utf8(b"u256"), 0x26);
        update_typed<vector<u8>>(&mutator, &string::utf8(b"bytes"), vector[0x02]);
        update_typed<String>(&mutator, &string::utf8(b"string"), string::utf8(b"ha"));

        assert!(!read_bool(&object, &string::utf8(b"bool")), 10);
        assert!(read_u8(&object, &string::utf8(b"u8")) == 0x21, 11);
        assert!(read_u16(&object, &string::utf8(b"u16")) == 0x22, 12);
        assert!(read_u32(&object, &string::utf8(b"u32")) == 0x23, 13);
        assert!(read_u64(&object, &string::utf8(b"u64")) == 0x24, 14);
        assert!(read_u128(&object, &string::utf8(b"u128")) == 0x25, 15);
        assert!(read_u256(&object, &string::utf8(b"u256")) == 0x26, 16);
        assert!(read_bytes(&object, &string::utf8(b"bytes")) == vector[0x02], 17);
        assert!(read_string(&object, &string::utf8(b"string")) == string::utf8(b"ha"), 18);

        assert!(length(&object) == 9, 19);

        remove(&mutator, &string::utf8(b"bool"));
        remove(&mutator, &string::utf8(b"u8"));
        remove(&mutator, &string::utf8(b"u16"));
        remove(&mutator, &string::utf8(b"u32"));
        remove(&mutator, &string::utf8(b"u64"));
        remove(&mutator, &string::utf8(b"u128"));
        remove(&mutator, &string::utf8(b"u256"));
        remove(&mutator, &string::utf8(b"bytes"));
        remove(&mutator, &string::utf8(b"string"));

        assert!(length(&object) == 0, 20);

        add_typed<bool>(&mutator, string::utf8(b"bool"), false);
        add_typed<u8>(&mutator, string::utf8(b"u8"), 0x21);
        add_typed<u16>(&mutator, string::utf8(b"u16"), 0x22);
        add_typed<u32>(&mutator, string::utf8(b"u32"), 0x23);
        add_typed<u64>(&mutator, string::utf8(b"u64"), 0x24);
        add_typed<u128>(&mutator, string::utf8(b"u128"), 0x25);
        add_typed<u256>(&mutator, string::utf8(b"u256"), 0x26);
        add_typed<vector<u8>>(&mutator, string::utf8(b"bytes"), vector[0x02]);
        add_typed<String>(&mutator, string::utf8(b"string"), string::utf8(b"ha"));

        assert!(!read_bool(&object, &string::utf8(b"bool")), 21);
        assert!(read_u8(&object, &string::utf8(b"u8")) == 0x21, 22);
        assert!(read_u16(&object, &string::utf8(b"u16")) == 0x22, 23);
        assert!(read_u32(&object, &string::utf8(b"u32")) == 0x23, 24);
        assert!(read_u64(&object, &string::utf8(b"u64")) == 0x24, 25);
        assert!(read_u128(&object, &string::utf8(b"u128")) == 0x25, 26);
        assert!(read_u256(&object, &string::utf8(b"u256")) == 0x26, 27);
        assert!(read_bytes(&object, &string::utf8(b"bytes")) == vector[0x02], 28);
        assert!(read_string(&object, &string::utf8(b"string")) == string::utf8(b"ha"), 29);

        assert!(length(&object) == 9, 30);

        remove(&mutator, &string::utf8(b"bool"));
        remove(&mutator, &string::utf8(b"u8"));
        remove(&mutator, &string::utf8(b"u16"));
        remove(&mutator, &string::utf8(b"u32"));
        remove(&mutator, &string::utf8(b"u64"));
        remove(&mutator, &string::utf8(b"u128"));
        remove(&mutator, &string::utf8(b"u256"));
        remove(&mutator, &string::utf8(b"bytes"));
        remove(&mutator, &string::utf8(b"string"));

        assert!(length(&object) == 0, 31);

        add(&mutator, string::utf8(b"bool"), string::utf8(b"bool"), bcs::to_bytes<bool>(&true));
        add(&mutator, string::utf8(b"u8"), string::utf8(b"u8"), bcs::to_bytes<u8>(&0x12));
        add(&mutator, string::utf8(b"u16"), string::utf8(b"u16"), bcs::to_bytes<u16>(&0x1234));
        add(&mutator, string::utf8(b"u32"), string::utf8(b"u32"), bcs::to_bytes<u32>(&0x12345678));
        add(&mutator, string::utf8(b"u64"), string::utf8(b"u64"), bcs::to_bytes<u64>(&0x1234567812345678));
        add(&mutator, string::utf8(b"u128"), string::utf8(b"u128"), bcs::to_bytes<u128>(&0x12345678123456781234567812345678));
        add(&mutator, string::utf8(b"u256"), string::utf8(b"u256"), bcs::to_bytes<u256>(&0x1234567812345678123456781234567812345678123456781234567812345678));
        add(&mutator, string::utf8(b"bytes"), string::utf8(b"bytes"), bcs::to_bytes<vector<u8>>(&vector[0x01]));
        add(&mutator, string::utf8(b"string"), string::utf8(b"string"), bcs::to_bytes<String>(&string::utf8(b"a")));

        assert!(read_bool(&object, &string::utf8(b"bool")), 32);
        assert!(read_u8(&object, &string::utf8(b"u8")) == 0x12, 33);
        assert!(read_u16(&object, &string::utf8(b"u16")) == 0x1234, 34);
        assert!(read_u32(&object, &string::utf8(b"u32")) == 0x12345678, 35);
        assert!(read_u64(&object, &string::utf8(b"u64")) == 0x1234567812345678, 36);
        assert!(read_u128(&object, &string::utf8(b"u128")) == 0x12345678123456781234567812345678, 37);
        assert!(read_u256(&object, &string::utf8(b"u256")) == 0x1234567812345678123456781234567812345678123456781234567812345678, 38);
        assert!(read_bytes(&object, &string::utf8(b"bytes")) == vector[0x01], 39);
        assert!(read_string(&object, &string::utf8(b"string")) == string::utf8(b"a"), 40);

        assert!(length(&object) == 9, 41);

        update(&mutator, &string::utf8(b"bool"), string::utf8(b"bool"), bcs::to_bytes<bool>(&false));
        update(&mutator, &string::utf8(b"u8"), string::utf8(b"u8"), bcs::to_bytes<u8>(&0x21));
        update(&mutator, &string::utf8(b"u16"), string::utf8(b"u16"), bcs::to_bytes<u16>(&0x22));
        update(&mutator, &string::utf8(b"u32"), string::utf8(b"u32"), bcs::to_bytes<u32>(&0x23));
        update(&mutator, &string::utf8(b"u64"), string::utf8(b"u64"), bcs::to_bytes<u64>(&0x24));
        update(&mutator, &string::utf8(b"u128"), string::utf8(b"u128"), bcs::to_bytes<u128>(&0x25));
        update(&mutator, &string::utf8(b"u256"), string::utf8(b"u256"), bcs::to_bytes<u256>(&0x26));
        update(&mutator, &string::utf8(b"bytes"), string::utf8(b"bytes"), bcs::to_bytes<vector<u8>>(&vector[0x02]));
        update(&mutator, &string::utf8(b"string"), string::utf8(b"string"), bcs::to_bytes<String>(&string::utf8(b"ha")));

        assert!(!read_bool(&object, &string::utf8(b"bool")), 10);
        assert!(read_u8(&object, &string::utf8(b"u8")) == 0x21, 11);
        assert!(read_u16(&object, &string::utf8(b"u16")) == 0x22, 12);
        assert!(read_u32(&object, &string::utf8(b"u32")) == 0x23, 13);
        assert!(read_u64(&object, &string::utf8(b"u64")) == 0x24, 14);
        assert!(read_u128(&object, &string::utf8(b"u128")) == 0x25, 15);
        assert!(read_u256(&object, &string::utf8(b"u256")) == 0x26, 16);
        assert!(read_bytes(&object, &string::utf8(b"bytes")) == vector[0x02], 17);
        assert!(read_string(&object, &string::utf8(b"string")) == string::utf8(b"ha"), 18);
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 0x10001, location = aptos_std::from_bcs)]
    fun test_invalid_init(creator: &signer) {
        let constructor_ref = object::create_named_object(creator, b"");

        let input = prepare_input(
            vector[string::utf8(b"bool")],
            vector[string::utf8(b"u16")],
            vector[bcs::to_bytes<bool>(&true)],
        );
        init(&constructor_ref, input);
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 0x10003, location = Self)]
    fun test_init_wrong_values(creator: &signer) {
        let constructor_ref = object::create_named_object(creator, b"");

        let input = prepare_input(
            vector[string::utf8(b"bool"), string::utf8(b"u8")],
            vector[string::utf8(b"bool"), string::utf8(b"u8")],
            vector[bcs::to_bytes<bool>(&true)],
        );
        init(&constructor_ref, input);
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 0x10004, location = Self)]
    fun test_init_wrong_types(creator: &signer) {
        let constructor_ref = object::create_named_object(creator, b"");

        let input = prepare_input(
            vector[string::utf8(b"bool"), string::utf8(b"u8")],
            vector[string::utf8(b"bool")],
            vector[bcs::to_bytes<bool>(&true), bcs::to_bytes<u8>(&0x2)],
        );
        init(&constructor_ref, input);
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 0x10001, location = aptos_std::from_bcs)]
    fun test_invalid_add(creator: &signer) acquires PropertyMap {
        let constructor_ref = object::create_named_object(creator, b"");

        let input = prepare_input(
            vector[string::utf8(b"bool")],
            vector[string::utf8(b"bool")],
            vector[bcs::to_bytes<bool>(&true)],
        );
        init(&constructor_ref, input);
        let mutator = generate_mutator_ref(&constructor_ref);

        update(&mutator, &string::utf8(b"u16"), string::utf8(b"bool"), bcs::to_bytes<u16>(&0x1234));
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 0x10001, location = aptos_std::from_bcs)]
    fun test_invalid_update(creator: &signer) acquires PropertyMap {
        let constructor_ref = object::create_named_object(creator, b"");

        let input = prepare_input(
            vector[string::utf8(b"bool")],
            vector[string::utf8(b"bool")],
            vector[bcs::to_bytes<bool>(&true)],
        );
        init(&constructor_ref, input);
        let mutator = generate_mutator_ref(&constructor_ref);

        update(&mutator, &string::utf8(b"bool"), string::utf8(b"bool"), bcs::to_bytes<u16>(&0x1234));
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 0x10008, location = Self)]
    fun test_invalid_read(creator: &signer) acquires PropertyMap {
        let constructor_ref = object::create_named_object(creator, b"");
        let object = object::object_from_constructor_ref<object::ObjectCore>(&constructor_ref);

        let input = prepare_input(
            vector[string::utf8(b"bool")],
            vector[string::utf8(b"bool")],
            vector[bcs::to_bytes<bool>(&true)],
        );
        init(&constructor_ref, input);
        read_u8(&object, &string::utf8(b"bool"));
    }
}
