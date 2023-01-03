// Copyright (c) Aptos
// SPDX-License-Identifier: Apache-2.0

use crate::quorum_store::batch_coordinator::BatchCoordinatorCommand;
use crate::quorum_store::batch_generator::BatchGeneratorCommand;
use crate::quorum_store::batch_store::BatchStoreCommand;
use crate::quorum_store::proof_coordinator::ProofCoordinatorCommand;
use crate::quorum_store::proof_manager::ProofManagerCommand;
use crate::round_manager::VerifiedEvent;
use aptos_channels::aptos_channel;
use aptos_consensus_types::proof_of_store::LogicalTime;
use aptos_crypto::HashValue;
use aptos_logger::prelude::*;
use aptos_types::account_address::AccountAddress;
use aptos_types::PeerId;
use futures::StreamExt;
use tokio::sync::mpsc;
use tokio::sync::oneshot;

pub enum CoordinatorCommand {
    CommitNotification(LogicalTime, Vec<HashValue>),
    Shutdown(futures_channel::oneshot::Sender<()>),
}

pub struct QuorumStoreCoordinator {
    my_peer_id: PeerId,
    batch_generator_cmd_tx: mpsc::Sender<BatchGeneratorCommand>,
    batch_coordinator_cmd_tx: mpsc::Sender<BatchCoordinatorCommand>,
    proof_coordinator_cmd_tx: mpsc::Sender<ProofCoordinatorCommand>,
    proof_manager_cmd_tx: mpsc::Sender<ProofManagerCommand>,
    batch_store_cmd_tx: mpsc::Sender<BatchStoreCommand>,
    quorum_store_msg_tx_vec: Vec<aptos_channel::Sender<AccountAddress, VerifiedEvent>>,
}

impl QuorumStoreCoordinator {
    pub(crate) fn new(
        my_peer_id: PeerId,
        batch_generator_cmd_tx: mpsc::Sender<BatchGeneratorCommand>,
        batch_coordinator_cmd_tx: mpsc::Sender<BatchCoordinatorCommand>,
        proof_coordinator_cmd_tx: mpsc::Sender<ProofCoordinatorCommand>,
        proof_manager_cmd_tx: mpsc::Sender<ProofManagerCommand>,
        batch_store_cmd_tx: mpsc::Sender<BatchStoreCommand>,
        quorum_store_msg_tx_vec: Vec<aptos_channel::Sender<AccountAddress, VerifiedEvent>>,
    ) -> Self {
        Self {
            my_peer_id,
            batch_generator_cmd_tx,
            batch_coordinator_cmd_tx,
            proof_coordinator_cmd_tx,
            proof_manager_cmd_tx,
            batch_store_cmd_tx,
            quorum_store_msg_tx_vec,
        }
    }

    pub async fn start(mut self, mut rx: futures_channel::mpsc::Receiver<CoordinatorCommand>) {
        while let Some(cmd) = rx.next().await {
            match cmd {
                CoordinatorCommand::CommitNotification(logical_time, digests) => {
                    self.proof_manager_cmd_tx
                        .send(ProofManagerCommand::CommitNotification(
                            logical_time,
                            digests,
                        ))
                        .await
                        .expect("Failed to send to ProofManager");

                    self.batch_generator_cmd_tx
                        .send(BatchGeneratorCommand::CommitNotification(logical_time))
                        .await
                        .expect("Failed to send to BatchGenerator");
                },
                CoordinatorCommand::Shutdown(ack_tx) => {
                    // TODO: shutdown batch generator and proof manager and batch coordinator

                    let (batch_store_shutdown_tx, batch_store_shutdown_rx) = oneshot::channel();
                    self.batch_store_cmd_tx
                        .send(BatchStoreCommand::Shutdown(batch_store_shutdown_tx))
                        .await
                        .expect("Failed to send to BatchStore");

                    batch_store_shutdown_rx
                        .await
                        .expect("Failed to stop BatchStore");

                    let (proof_coordinator_shutdown_tx, proof_coordinator_shutdown_rx) =
                        oneshot::channel();
                    self.proof_coordinator_cmd_tx
                        .send(ProofCoordinatorCommand::Shutdown(
                            proof_coordinator_shutdown_tx,
                        ))
                        .await
                        .expect("Failed to send to ProofCoordinator");

                    proof_coordinator_shutdown_rx
                        .await
                        .expect("Failed to stop ProofCoordinator");

                    for network_listener_tx in self.quorum_store_msg_tx_vec {
                        let (network_listener_shutdown_tx, network_listener_shutdown_rx) =
                            oneshot::channel();
                        match network_listener_tx.push(
                            self.my_peer_id,
                            VerifiedEvent::Shutdown(network_listener_shutdown_tx),
                        ) {
                            Ok(()) => debug!("QS: shutdown network listener sent"),
                            Err(err) => panic!("Failed to send to NetworkListener, Err {:?}", err),
                        };
                        network_listener_shutdown_rx
                            .await
                            .expect("Failed to stop NetworkListener");
                    }

                    ack_tx
                        .send(())
                        .expect("Failed to send shutdown ack from QuorumStore");
                    break;
                },
            }
        }
    }
}