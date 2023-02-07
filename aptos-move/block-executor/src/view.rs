// Copyright (c) Aptos
// SPDX-License-Identifier: Apache-2.0

use crate::{
    counters,
    scheduler::{Scheduler, TxnIndex},
    task::{ModulePath, Transaction},
    txn_last_input_output::ReadDescriptor,
};
use anyhow::Result;
use aptos_aggregator::delta_change_set::{deserialize, serialize, DeltaOp};
use aptos_mvhashmap::{MVHashMap, MVHashMapError, MVHashMapOutput};
use aptos_state_view::{StateViewId, TStateView};
use aptos_types::{
    state_store::state_storage_usage::StateStorageUsage,
    vm_status::{StatusCode, VMStatus},
};
use aptos_vm_types::data_cache::{Cache, CachedData, DataCache, Readable};
use move_binary_format::errors::Location;
use move_core_types::value::MoveTypeLayout;
use move_vm_types::values::Value;
use std::{cell::RefCell, collections::BTreeMap, hash::Hash, sync::Arc};

/// Resolved and serialized data for WriteOps, None means deletion.
pub type ResolvedData = Option<Vec<u8>>;

/// A struct that is always used by a single thread performing an execution task. The struct is
/// passed to the VM and acts as a proxy to resolve reads first in the shared multi-version
/// data-structure. It also allows the caller to track the read-set and any dependencies.
///
/// TODO(issue 10177): MvHashMapView currently needs to be sync due to trait bounds, but should
/// not be. In this case, the read_dependency member can have a RefCell<bool> type and the
/// captured_reads member can have RefCell<Vec<ReadDescriptor<K>>> type.
pub(crate) struct MVHashMapView<'a, K, V: Readable> {
    versioned_map: &'a MVHashMap<K, V>,
    scheduler: &'a Scheduler,
    captured_reads: RefCell<Vec<ReadDescriptor<K>>>,
}

/// A struct which describes the result of the read from the proxy. The client
/// can interpret these types to further resolve the reads.
#[derive(Debug)]
pub enum ReadResult<V> {
    // Successful read of a value.
    Value(V),
    // Similar to above, but the value was aggregated and is an integer.
    U128(u128),
    // Read failed while resolving a delta.
    Unresolved(DeltaOp),
    // Read did not return anything.
    None,
}

impl<
        'a,
        K: ModulePath + PartialOrd + Ord + Send + Clone + Hash + Eq,
        V: Send + Sync + Clone + Readable,
    > MVHashMapView<'a, K, V>
{
    pub(crate) fn new(versioned_map: &'a MVHashMap<K, V>, scheduler: &'a Scheduler) -> Self {
        Self {
            versioned_map,
            scheduler,
            captured_reads: RefCell::new(Vec::new()),
        }
    }

    /// Drains the captured reads.
    pub(crate) fn take_reads(&self) -> Vec<ReadDescriptor<K>> {
        self.captured_reads.take()
    }

    /// Captures a read from the VM execution.
    fn read(&self, key: &K, txn_idx: TxnIndex) -> ReadResult<V> {
        use MVHashMapError::*;
        use MVHashMapOutput::*;

        loop {
            match self.versioned_map.read(key, txn_idx) {
                Ok(Version(version, v)) => {
                    let (idx, incarnation) = version;
                    self.captured_reads
                        .borrow_mut()
                        .push(ReadDescriptor::from_version(key.clone(), idx, incarnation));
                    return ReadResult::Value(v);
                },
                Ok(Resolved(value)) => {
                    self.captured_reads
                        .borrow_mut()
                        .push(ReadDescriptor::from_resolved(key.clone(), value));
                    return ReadResult::U128(value);
                },
                Err(NotFound) => {
                    self.captured_reads
                        .borrow_mut()
                        .push(ReadDescriptor::from_storage(key.clone()));
                    return ReadResult::None;
                },
                Err(Unresolved(delta)) => {
                    self.captured_reads
                        .borrow_mut()
                        .push(ReadDescriptor::from_unresolved(key.clone(), delta));
                    return ReadResult::Unresolved(delta);
                },
                Err(Dependency(dep_idx)) => {
                    // `self.txn_idx` estimated to depend on a write from `dep_idx`.
                    match self.scheduler.wait_for_dependency(txn_idx, dep_idx) {
                        Some(dep_condition) => {
                            let _timer = counters::DEPENDENCY_WAIT_SECONDS.start_timer();
                            // Wait on a condition variable corresponding to the encountered
                            // read dependency. Once the dep_idx finishes re-execution, scheduler
                            // will mark the dependency as resolved, and then the txn_idx will be
                            // scheduled for re-execution, which will re-awaken cvar here.
                            // A deadlock is not possible due to these condition variables:
                            // suppose all threads are waiting on read dependency, and consider
                            // one with lowest txn_idx. It observed a dependency, so some thread
                            // aborted dep_idx. If that abort returned execution task, by
                            // minimality (lower transactions aren't waiting), that thread would
                            // finish execution unblock txn_idx, contradiction. Otherwise,
                            // execution_idx in scheduler was lower at a time when at least the
                            // thread that aborted dep_idx was alive, and again, since lower txns
                            // than txn_idx are not blocked, so the execution of dep_idx will
                            // eventually finish and lead to unblocking txn_idx, contradiction.
                            let (lock, cvar) = &*dep_condition;
                            let mut dep_resolved = lock.lock();
                            while !*dep_resolved {
                                dep_resolved = cvar.wait(dep_resolved).unwrap();
                            }
                        },
                        None => continue,
                    }
                },
                Err(DeltaApplicationFailure) => {
                    // Delta application failure currently should never happen. Here, we assume it
                    // happened because of speculation and return 0 to the Move-VM. Validation will
                    // ensure the transaction re-executes if 0 wasn't the right number.
                    self.captured_reads
                        .borrow_mut()
                        .push(ReadDescriptor::from_delta_application_failure(key.clone()));
                    return ReadResult::U128(0);
                },
            };
        }
    }
}

enum ViewMapKind<'a, T: Transaction> {
    MultiVersion(&'a MVHashMapView<'a, T::Key, T::ReadValue>),
    BTree(&'a BTreeMap<T::Key, T::ReadValue>),
}

pub(crate) struct LatestView<'a, T: Transaction, S: TStateView<Key = T::Key>> {
    base_view: &'a S,
    latest_view: ViewMapKind<'a, T>,
    txn_idx: TxnIndex,
}

impl<'a, T: Transaction, S: TStateView<Key = T::Key>> LatestView<'a, T, S> {
    pub(crate) fn new_mv_view(
        base_view: &'a S,
        map: &'a MVHashMapView<'a, T::Key, T::ReadValue>,
        txn_idx: TxnIndex,
    ) -> LatestView<'a, T, S> {
        LatestView {
            base_view,
            latest_view: ViewMapKind::MultiVersion(map),
            txn_idx,
        }
    }

    pub(crate) fn new_btree_view(
        base_view: &'a S,
        map: &'a BTreeMap<T::Key, T::ReadValue>,
        txn_idx: TxnIndex,
    ) -> LatestView<'a, T, S> {
        LatestView {
            base_view,
            latest_view: ViewMapKind::BTree(map),
            txn_idx,
        }
    }
}

impl<'a, T: Transaction, S: TStateView<Key = T::Key>> DataCache for LatestView<'a, T, S> {
    type DeserializerHint = MoveTypeLayout;
    type Key = T::Key;

    fn get_value(
        &self,
        key: &T::Key,
        hint: Option<&MoveTypeLayout>,
    ) -> anyhow::Result<Option<CachedData>> {
        match self.latest_view {
            ViewMapKind::MultiVersion(map) => match map.read(key, self.txn_idx) {
                ReadResult::Value(v) => Ok(v.read()),
                // TODO: This seems very unnecessary, can we pass u128 instead?
                ReadResult::U128(v) => Ok(Some(CachedData::MoveValue(Arc::new(Value::u128(v))))),
                ReadResult::Unresolved(delta) => {
                    let from_storage = self
                        .base_view
                        .get_state_value(key)?
                        .map_or(Err(VMStatus::Error(StatusCode::STORAGE_ERROR)), |bytes| {
                            Ok(deserialize(&bytes))
                        })?;
                    let result = delta
                        .apply_to(from_storage)
                        .map_err(|pe| pe.finish(Location::Undefined).into_vm_status())?;

                    // TODO: Should we cache this into map?
                    Ok(Some(CachedData::MoveValue(Arc::new(Value::u128(result)))))
                },
                ReadResult::None => {
                    self.base_view.get_state_value(key).map(|maybe_blob| {
                        maybe_blob.map(|blob| {
                            match hint {
                                Some(layout) => {
                                    // TODO: Propagate error?
                                    let value = Value::simple_deserialize(&blob, layout)
                                        .expect("should deserialize");
                                    CachedData::MoveValue(Arc::new(value))
                                },
                                None => CachedData::Serialized(Arc::new(blob)),
                            }
                        })
                    })
                },
            },
            ViewMapKind::BTree(map) => map.get(key).map_or_else(
                || {
                    let blob = self.base_view.get_state_value(key);
                    // TODO: Cache value here?
                    blob.map(|maybe_blob| {
                        maybe_blob.map(|blob| {
                            match hint {
                                Some(layout) => {
                                    // TODO: Propagate error?
                                    let value = Value::simple_deserialize(&blob, layout)
                                        .expect("should deserialize");
                                    CachedData::MoveValue(Arc::new(value))
                                },
                                None => CachedData::Serialized(Arc::new(blob)),
                            }
                        })
                    })

                    // TODO: common treatment with the above case.
                    // TODO: enable below when logging isn't a circular dependency.
                    // Even speculatively, reading from base view should not return an error.
                    // let log_context = AdapterLogSchema::new(self.base_view.id(), self.txn_idx);
                    // error!(
                    //     log_context,
                    //     "[VM, StateView] Error getting data from storage for {:?}", state_key
                    // );
                    // Alert (increase critical error count).
                    // log_context.alert();
                    // ret
                },
                |v| Ok(v.read_ref()),
            ),
        }
    }
}
