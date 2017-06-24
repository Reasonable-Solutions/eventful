{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

module Eventful.ProjectionCache.Types
  ( ProjectionCache (..)
  , StreamProjectionCache
  , GloballyOrderedProjectionCache
  , runProjectionCacheUsing
  , serializedProjectionCache
  , getLatestProjectionWithCache
  , getLatestGlobalProjectionWithCache
  , updateProjectionCache
  , updateGlobalProjectionCache
  ) where

import Eventful.Projection
import Eventful.Serializer
import Eventful.Store.Class
import Eventful.UUID

-- | A 'ProjectionCache' caches snapshots of 'Projection's in event streams.
-- This is useful if your event streams are very large. This cache operates on
-- some 'Monad' @m@ and stores the 'Projection' state of type @serialized@.
--
-- At its core, this is essentially just a key-value store with knowledge of
-- the stream 'UUID' and 'EventVersion'. It is recommended to use the other
-- helper functions in this module to interpret the stored values using a
-- 'Projection'.
--
-- The @key@ and @orderKey@ type parameters are polymorphic so we can abstract
-- over a cache for individual event streams, and a cache for globally ordered
-- streams.
data ProjectionCache key orderKey serialized m
  = ProjectionCache
  { storeProjectionSnapshot :: key -> orderKey -> serialized -> m ()
    -- ^ Stores the state for a projection at a given @key@ and @orderKey@.
    -- This is pretty unsafe, because there is no guarantee what is stored is
    -- actually derived from the events in the stream. Consider using
    -- 'updateProjectionCache'.
  , loadProjectionSnapshot :: key -> m (Maybe (orderKey, serialized))
    -- ^ Loads the latest projection state from the cache.
  }

-- | Type synonym for a 'ProjectionCache' used on individual event streams.
type StreamProjectionCache serialized m = ProjectionCache UUID EventVersion serialized m

-- | Type synonym for a 'ProjectionCache' that is used in conjunction with a
-- 'GloballyOrderedEventStore'.
type GloballyOrderedProjectionCache key serialized m = ProjectionCache key SequenceNumber serialized m

-- | Changes the monad a 'ProjectionCache' runs in. This is useful to run the
-- cache in another 'Monad' while forgetting the original 'Monad'.
runProjectionCacheUsing
  :: (Monad m, Monad mstore)
  => (forall a. mstore a -> m a)
  -> ProjectionCache key orderKey serialized mstore
  -> ProjectionCache key orderKey serialized m
runProjectionCacheUsing runCache ProjectionCache{..} =
  ProjectionCache
  { storeProjectionSnapshot = \uuid version state -> runCache $ storeProjectionSnapshot uuid version state
  , loadProjectionSnapshot = runCache . loadProjectionSnapshot
  }

-- | Wraps a 'ProjectionCache' and transparently serializes/deserializes events for
-- you. Note that in this implementation deserialization errors when using
-- 'getEvents' are simply ignored (the event is not returned).
serializedProjectionCache
  :: (Monad m)
  => Serializer state serialized
  -> ProjectionCache key orderKey serialized m
  -> ProjectionCache key orderKey state m
serializedProjectionCache Serializer{..} ProjectionCache{..} =
  ProjectionCache storeProjectionSnapshot' loadProjectionSnapshot'
  where
    storeProjectionSnapshot' uuid version = storeProjectionSnapshot uuid version . serialize
    loadProjectionSnapshot' uuid = do
      mState <- loadProjectionSnapshot uuid
      return $ mState >>= traverse deserialize

-- | Like 'getLatestProjection', but uses a 'ProjectionCache' if it contains
-- more recent state.
getLatestProjectionWithCache
  :: (Monad m)
  => EventStore event m
  -> StreamProjectionCache state m
  -> StreamProjection state event
  -> m (StreamProjection state event)
getLatestProjectionWithCache store cache originalProj = do
  mLatestState <- loadProjectionSnapshot cache (streamProjectionUuid originalProj)
  let
    mkProjection' (version, state) =
      if version > streamProjectionVersion originalProj
      then
        originalProj
        { streamProjectionVersion = version
        , streamProjectionState = state
        }
      else originalProj
    projection' = maybe originalProj mkProjection' mLatestState
  getLatestProjection store projection'

-- | Like 'getLatestGlobalProjection', but uses a 'ProjectionCache' if it
-- contains more recent state.
getLatestGlobalProjectionWithCache
  :: (Monad m)
  => GloballyOrderedEventStore event m
  -> GloballyOrderedProjectionCache key state m
  -> GloballyOrderedProjection state event
  -> key
  -> m (GloballyOrderedProjection state event)
getLatestGlobalProjectionWithCache store cache originalProj key = do
  mLatestState <- loadProjectionSnapshot cache key
  let
    mkProjection' (seqNum, state) =
      if seqNum > globallyOrderedProjectionSequenceNumber originalProj
      then
        originalProj
        { globallyOrderedProjectionSequenceNumber = seqNum
        , globallyOrderedProjectionState = state
        }
      else originalProj
    projection' = maybe originalProj mkProjection' mLatestState
  getLatestGlobalProjection store projection'

-- | Loads the latest projection state from the cache/store and stores this
-- value back into the projection cache.
updateProjectionCache
  :: (Monad m)
  => EventStore event m
  -> StreamProjectionCache state m
  -> StreamProjection state event
  -> m ()
updateProjectionCache store cache projection = do
  StreamProjection{..} <- getLatestProjectionWithCache store cache projection
  storeProjectionSnapshot cache streamProjectionUuid streamProjectionVersion streamProjectionState

-- | Analog of 'updateProjectionCache' for a 'GloballyOrderedProjectionCache'.
updateGlobalProjectionCache
  :: (Monad m)
  => GloballyOrderedEventStore event m
  -> GloballyOrderedProjectionCache key state m
  -> GloballyOrderedProjection state event
  -> key
  -> m ()
updateGlobalProjectionCache store cache projection key = do
  GloballyOrderedProjection{..} <- getLatestGlobalProjectionWithCache store cache projection key
  storeProjectionSnapshot cache key globallyOrderedProjectionSequenceNumber globallyOrderedProjectionState