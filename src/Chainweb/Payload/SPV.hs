{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Payload.SPV
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Payload.SPV
(
-- * Transaction Proofs
  TransactionProof
, createTransactionProof
, runTransactionProof
, verifyTransactionProof

-- * Transaction Output Proofs
, TransactionOutputProof
, createTransactionOutputProof
, runTransactionOutputProof
, verifyTransactionOutputProof
) where

import Control.Lens
import Control.Monad
import Control.Monad.Catch

import Crypto.Hash.Algorithms

import qualified Data.ByteString as B
import qualified Data.List.NonEmpty as N
import Data.Maybe
import Data.MerkleLog
import Data.Reflection (Given, give, given)
import qualified Data.Text as T

import GHC.Stack

import Prelude hiding (lookup)

-- internal modules

import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.ChainId
import Chainweb.Crypto.MerkleLog
import Chainweb.CutDB
import Chainweb.Graph
import Chainweb.MerkleLogHash
import Chainweb.MerkleUniverse
import Chainweb.Payload
import Chainweb.Payload.PayloadStore
import Chainweb.TreeDB
import Chainweb.Utils
import Chainweb.WebBlockHeaderDB

import Data.CAS

-- -------------------------------------------------------------------------- --
-- Exceptions

data SpvException
    = SpvExceptionTargetNotReachable
        { _spvExceptionMsg :: !T.Text
        , _spvExceptionSourceChainId :: !ChainId
        , _spvExceptionSourceHeight :: !BlockHeight
        , _spvExceptionTargetChainId :: !ChainId
        , _spvExceptionTargetHeight :: !BlockHeight
        }
    | SpvExceptionInconsistentPayloadData
        { _spvExceptionMsg :: !T.Text
        , _spvExceptionMsgPayloadHash :: !BlockPayloadHash
        }
    | SpvExceptionVerificationFailed
        { _spvExceptionMsg :: !T.Text
        }
    deriving (Show)

instance Exception SpvException

-- -------------------------------------------------------------------------- --
-- Transaction Proofs

-- | Witness that a transaction is included in the head of a chain in a
-- chainweb.
--
data TransactionProof a = TransactionProof ChainId (MerkleProof a)
    deriving (Show)

-- | Runs a transaction Proof. Returns the block hash on the target chain for
-- which inclusion is proven.
--
runTransactionProof :: TransactionProof SHA512t_256 -> BlockHash
runTransactionProof (TransactionProof _ p)
    = BlockHash $ MerkleLogHash $ runMerkleProof p

verifyTransactionProof
    :: CutDb
    -> TransactionProof SHA512t_256
    -> IO Transaction
verifyTransactionProof cutDb proof@(TransactionProof cid p) = do
    unlessM (member cutDb cid h) $ throwM
        $ SpvExceptionVerificationFailed "target header is not in the chain"
    proofSubject p
  where
    h = runTransactionProof proof

-- | Creates a witness that a transaction in is included in the head
-- of a chain in a chainweb.
--
createTransactionProof
    :: HasCallStack
    => PayloadCas cas
    => CutDb
        -- ^ Block Header Database
    -> PayloadDb cas
        -- ^ Payload Database
    -> ChainId
        -- ^ target chain. The proof asserts that the subject
        -- is included in the head of this chain.
    -> ChainId
        -- ^ source chain. This the chain of the subject
    -> BlockHeight
        -- ^ The block height of the transaction
    -> Int
        -- ^ The index of the transaction in the block
    -> IO (TransactionProof SHA512t_256)
createTransactionProof cutDb payloadCas tcid scid bh i = TransactionProof tcid
    <$> createPayloadProof transactionProofPrefix cutDb payloadCas tcid scid bh i

-- -------------------------------------------------------------------------- --
-- Output Proofs

-- | Witness that a transaction output is included in the head of a chain in a
-- chainweb.
--
data TransactionOutputProof a = TransactionOutputProof ChainId (MerkleProof a)
    deriving (Show)

-- | Runs a transaction Proof. Returns the block hash on the target chain for
-- which inclusion is proven.
--
runTransactionOutputProof :: TransactionOutputProof SHA512t_256 -> BlockHash
runTransactionOutputProof (TransactionOutputProof _ p)
    = BlockHash $ MerkleLogHash $ runMerkleProof p

verifyTransactionOutputProof
    :: CutDb
    -> TransactionOutputProof SHA512t_256
    -> IO TransactionOutput
verifyTransactionOutputProof cutDb proof@(TransactionOutputProof cid p) = do
    unlessM (member cutDb cid h) $ throwM
        $ SpvExceptionVerificationFailed "target header is not in the chain"
    proofSubject p
  where
    h = runTransactionOutputProof proof

-- | Creates a witness that a transaction in is included in the head
-- of a chain in a chainweb.
--
createTransactionOutputProof
    :: HasCallStack
    => PayloadCas cas
    => CutDb
        -- ^ Block Header Database
    -> PayloadDb cas
        -- ^ Payload Database
    -> ChainId
        -- ^ target chain. The proof asserts that the subject
        -- is included in the head of this chain.
    -> ChainId
        -- ^ source chain. This the chain of the subject
    -> BlockHeight
        -- ^ The block height of the transaction
    -> Int
        -- ^ The index of the transaction in the block
    -> IO (TransactionOutputProof SHA512t_256)
createTransactionOutputProof cutDb payloadCas tcid scid bh i
    = TransactionOutputProof tcid
        <$> createPayloadProof outputProofPrefix cutDb payloadCas tcid scid bh i

-- -------------------------------------------------------------------------- --
-- Internal Proof Creation

-- | The PayloadProofPrefix is the subject along with the prefix of the list
-- of merkle trees for the final proof.
--
type PayloadProofPrefix =
    (MerkleNodeType SHA512t_256 B.ByteString, N.NonEmpty (Int, MerkleTree SHA512t_256))

-- | Creates a witness that a transaction in is included in the head
-- of a chain in a chainweb.
--
createPayloadProof
    :: HasCallStack
    => PayloadCas cas
    => (Int -> PayloadDb cas -> BlockPayload -> IO PayloadProofPrefix)
    -> CutDb
        -- ^ Block Header Database
    -> PayloadDb cas
        -- ^ Payload Database
    -> ChainId
        -- ^ target chain. The proof asserts that the subject
        -- is included in the head of this chain.
    -> ChainId
        -- ^ source chain. This the chain of the subject
    -> BlockHeight
        -- ^ The block height of the transaction
    -> Int
        -- ^ The index of the transaction in the block
    -> IO (MerkleProof SHA512t_256)
createPayloadProof getPrefix cutDb payloadDb tcid scid txHeight txIx = give headerDb $ do
    --
    -- 1. TransactionTree
    -- 2. BlockPayload
    -- 3. BlockHeader
    -- 4. BlockHeaderParent Chain
    -- 5. BlockHeaderAdjacentParent Chain
    --
    -- TODO: verify inputs?
    --

    -- For large bodies one should work with the MerkleLog object, for empty or
    -- small bodies one can work with the type directly
    --
    -- Rule of thumb:
    --
    -- If a specialized function for creating a MerkleLog is provided by the API
    -- it should be used.
    --

    trgHeadHeader <- maxHeader trgChain

    -- crossChain == ]srcHeadHeader, trgHeadHeader]
    (srcHeadHeader, crossChain) <- crumbsToChain scid trgHeadHeader >>= \case
        Just x -> return x
        Nothing -> throwM $ SpvExceptionTargetNotReachable
            { _spvExceptionMsg = "target chain not reachabe. Chainweb instance is to young"
            , _spvExceptionSourceChainId = scid
            , _spvExceptionSourceHeight = txHeight
            , _spvExceptionTargetChainId = tcid
            , _spvExceptionTargetHeight = _blockHeight trgHeadHeader
            }

    unless (_blockHeight srcHeadHeader >= txHeight)
        $ throwM $ SpvExceptionTargetNotReachable
            { _spvExceptionMsg = "Target of SPV proof can't be reached from the source transaction"
            , _spvExceptionSourceChainId = scid
            , _spvExceptionSourceHeight = txHeight
            , _spvExceptionTargetChainId = tcid
            , _spvExceptionTargetHeight = _blockHeight trgHeadHeader
            }

    -- chain == [srcHeader, srcHeadHeader]
    (txHeader N.:| chain) <- crumbsOnChain srcHeadHeader txHeight >>= \case
        Just x -> return x
        Nothing -> throwM $ SpvExceptionTargetNotReachable
            { _spvExceptionMsg = "Target of SPV proof can't be reached from the source transaction"
            , _spvExceptionSourceChainId = scid
            , _spvExceptionSourceHeight = txHeight
            , _spvExceptionTargetChainId = tcid
            , _spvExceptionTargetHeight = _blockHeight trgHeadHeader
            }

    Just payload <- casLookup pDb (_blockPayloadHash txHeader)

    -- ----------------------------- --
    -- 1. Payload Proofs (TXs and Payload)

    (subj, prefix) <- getPrefix txIx payloadDb payload

    -- ----------------------------- --

    -- 2. BlockHeader proof
    --
    unless (_blockPayloadHash txHeader == _blockPayloadPayloadHash payload)
        $ throwM $ SpvExceptionInconsistentPayloadData
            { _spvExceptionMsg = "The stored payload hash doesn't match the the db index"
            , _spvExceptionMsgPayloadHash = _blockPayloadHash txHeader
            }
            -- this indicates that the payload store is inconsistent
    let blockHeaderTree = headerTree_ @BlockPayloadHash txHeader

    -- 3. BlockHeader Chain Proof
    --
    let chainTrees = headerTree_ @BlockHash <$> chain

    -- 4. Cross Chain Proof
    --
    let crossTrees = uncurry (flip bodyTree_) <$> crossChain

    -- Put proofs together
    --
    merkleProof_ subj $ append prefix
        $ blockHeaderTree
        : chainTrees
        <> crossTrees

  where
    pDb = _transactionDbBlockPayloads $ _transactionDb payloadDb
    trgChain = headerDb ^?! ixg tcid
    headerDb = view cutDbWebBlockHeaderDb cutDb

    append :: N.NonEmpty a -> [a] -> N.NonEmpty a
    append (h N.:| t) l = h N.:| (t <> l)

transactionProofPrefix
    :: PayloadCas cas
    => Int
    -> PayloadDb cas
    -> BlockPayload
    -> IO PayloadProofPrefix
transactionProofPrefix i db payload = do
    -- 1. TX proof
    Just outs <- casLookup cas $ _blockPayloadTransactionsHash payload
        -- TODO: use the transaction tree cache
    let (subj, pos, t) = bodyTree @ChainwebHashTag outs i
        -- FIXME use log
    let tree = (pos, t)
        -- we blindly trust the ix

    -- 2. Payload proof
    return (subj, tree N.:| [headerTree_ @BlockTransactionsHash payload])
  where
    cas = _transactionDbBlockTransactions $ _transactionDb db

outputProofPrefix
    :: PayloadCas cas
    => Int
    -> PayloadDb cas
    -> BlockPayload
    -> IO PayloadProofPrefix
outputProofPrefix i db payload = do
    -- 1. TX proof
    Just outs <- casLookup cas $ _blockPayloadOutputsHash payload
        -- TODO: use the transaction tree cache
    let (subj, pos, t) = bodyTree @ChainwebHashTag outs i
        -- FIXME use log
    let tree = (pos, t)
        -- we blindly trust the ix

    -- 2. Payload proof
    return (subj, tree N.:| [headerTree_ @BlockOutputsHash payload])
  where
    cas = _payloadCacheBlockOutputs $ _payloadCache db

-- -------------------------------------------------------------------------- --
-- Utils

-- | Walk down a chain along the parent relation and create a path of bread
-- crumbs from the target header to the source height
--
-- Returns 'Nothing' if @i >= _blockHeight h@.
--
crumbsOnChain
    :: Given WebBlockHeaderDb
    => BlockHeader
    -> BlockHeight
    -> IO (Maybe (N.NonEmpty BlockHeader))
crumbsOnChain trgHeader srcHeight
    | srcHeight > _blockHeight trgHeader = return Nothing
    | otherwise = Just <$> go trgHeader []
  where
    go cur acc
        | srcHeight == _blockHeight cur = return (cur N.:| acc)
        | otherwise = do
            p <- lookupParentHeader cur
            go p (cur : acc)

-- | Create a path of bread crumbs from the source chain id to the target header
-- along the adjancet parent relation.
--
-- Returns 'Nothing' no such path exists.
--
crumbsToChain
    :: Given WebBlockHeaderDb
    => ChainId
    -> BlockHeader
    -> IO (Maybe (BlockHeader, [(Int, BlockHeader)]))
        -- ^ bread crumbs that lead from to source Chain to targetHeader
crumbsToChain srcCid trgHeader
    | (int (_blockHeight trgHeader) + 1) < length path = return Nothing
    | otherwise = Just <$> go trgHeader path []
  where
    graph = _chainGraph @WebBlockHeaderDb given
    path = shortestPath (_chainId trgHeader) srcCid graph

    go
        :: BlockHeader
        -> [ChainId]
        -> [(Int, BlockHeader)]
        -> IO (BlockHeader, [(Int, BlockHeader)])
    go cur [] acc = return (cur, acc)
    go cur (h:t) acc = do
        adjpHdr <- lookupAdjacentParentHeader cur h
        unless (_blockHeight adjpHdr >= 0) $ throwM
            $ InternalInvariantViolation
            $ "crumbsToChain: Encountered Genesis block. Chain can't be reached for SPV proof."

        let adjIdx = fromJust $ blockHashRecordChainIdx (_blockAdjacentHashes cur) h
        go adjpHdr t ((adjIdx, cur) : acc)

