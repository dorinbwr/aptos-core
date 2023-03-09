// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

#![forbid(unsafe_code)]

use crate::db_options::{gen_state_kv_cfds, state_kv_db_column_families};
use anyhow::Result;
use aptos_config::config::{RocksdbConfig, RocksdbConfigs};
use aptos_rocksdb_options::gen_rocksdb_options;
use aptos_schemadb::DB;
use arr_macro::arr;
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

pub const STATE_KV_DB_NAME: &str = "state_kv_db";
pub const STATE_KV_METADATA_DB_NAME: &str = "state_kv_metadata_db";
pub const STATE_KV_SHARDS: &str = "";

pub struct StateKvDb {
    state_kv_metadata_db: Arc<DB>,
    state_kv_db_shards: [Arc<DB>; 256],
}

impl StateKvDb {
    // TODO(grao): Support more flexible path to make it easier for people to put different shards
    // on different disks.
    pub fn open<P: AsRef<Path>>(
        db_root_path: P,
        rocksdb_configs: RocksdbConfigs,
        readonly: bool,
        ledger_db: Arc<DB>,
    ) -> Result<Self> {
        if !rocksdb_configs.use_state_kv_db {
            return Ok(Self {
                state_kv_metadata_db: Arc::clone(&ledger_db),
                state_kv_db_shards: arr![Arc::clone(&ledger_db); 256],
            });
        }

        let state_kv_metadata_db_path = db_root_path
            .as_ref()
            .join(STATE_KV_DB_NAME)
            .join("metadata");

        let state_kv_metadata_db = Arc::new(if readonly {
            DB::open_cf_readonly(
                &gen_rocksdb_options(&rocksdb_configs.state_kv_db_config, true),
                state_kv_metadata_db_path.clone(),
                STATE_KV_METADATA_DB_NAME,
                state_kv_db_column_families(),
            )?
        } else {
            DB::open_cf(
                &gen_rocksdb_options(&rocksdb_configs.state_kv_db_config, false),
                state_kv_metadata_db_path.clone(),
                STATE_KV_METADATA_DB_NAME,
                gen_state_kv_cfds(&rocksdb_configs.state_kv_db_config),
            )?
        });

        let mut shard_id: usize = 0;
        let state_kv_db_shards: [Arc<DB>; 256] = arr![{
            let db = Self::open_shard(db_root_path, shard_id as u8, readonly)?;
            shard_id += 1;
            Arc::new(db)
        }; 256];

        Ok(Self {
            state_kv_metadata_db,
            state_kv_db_shards,
        })
    }

    fn open_shard<P: AsRef<Path>>(
        db_root_path: P,
        shard_id: u8,
        state_kv_db_config: RocksdbConfig,
        readonly: bool,
    ) -> Result<DB> {
        let path = db_root_path.as_ref().join(STATE_KV_DB_NAME).join(shard_id);
        Self::open_db(path, "name", state_kv_db_config, readonly)
    }

    fn open_db(
        path: PathBuf,
        name: &str,
        state_kv_db_config: RocksdbConfig,
        readonly: bool,
    ) -> Result<DB> {
        Ok(if readonly {
            DB::open_cf_readonly(
                &gen_rocksdb_options(&state_kv_db_config, true),
                path,
                name,
                state_kv_db_column_families(),
            )?
        } else {
            DB::open_cf(
                &gen_rocksdb_options(&state_kv_db_config, false),
                path,
                name,
                gen_state_kv_cfds(&state_kv_db_config),
            )?
        })
    }
}
