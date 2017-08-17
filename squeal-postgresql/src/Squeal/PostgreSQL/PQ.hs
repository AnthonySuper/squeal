{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE
    DataKinds
  , DefaultSignatures
  , FunctionalDependencies
  , PolyKinds
  , DeriveFunctor
  , FlexibleContexts
  , FlexibleInstances
  , MagicHash
  , MultiParamTypeClasses
  , OverloadedStrings
  , RankNTypes
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.PQ where

import Control.Exception.Lifted
import Control.Monad.Base
import Control.Monad.Except
import Control.Monad.Trans.Control
import Data.ByteString (ByteString)
import Data.Foldable
import Data.Function ((&))
import Data.Monoid
import Data.Traversable
import Generics.SOP
import GHC.Exts hiding (fromList)
import GHC.TypeLits

import qualified Database.PostgreSQL.LibPQ as LibPQ

import Squeal.PostgreSQL.Binary
import Squeal.PostgreSQL.Statement
import Squeal.PostgreSQL.Schema

newtype Connection (schema :: [(Symbol,[(Symbol,ColumnType)])]) =
  Connection { unConnection :: LibPQ.Connection }

newtype PQ
  (schema0 :: [(Symbol,[(Symbol,ColumnType)])])
  (schema1 :: [(Symbol,[(Symbol,ColumnType)])])
  (m :: * -> *)
  (x :: *) =
    PQ { runPQ :: Connection schema0 -> m (x, Connection schema1) }
    deriving Functor

evalPQ :: Functor m => PQ schema0 schema1 m x -> Connection schema0 -> m x
evalPQ (PQ pq) = fmap fst . pq

execPQ
  :: Functor m
  => PQ schema0 schema1 m x
  -> Connection schema0
  -> m (Connection schema1)
execPQ (PQ pq) = fmap snd . pq

pqAp
  :: Monad m
  => PQ schema0 schema1 m (x -> y)
  -> PQ schema1 schema2 m x
  -> PQ schema0 schema2 m y
pqAp (PQ f) (PQ x) = PQ $ \ conn -> do
  (f', conn') <- f conn
  (x', conn'') <- x conn'
  return (f' x', conn'')

pqBind
  :: Monad m
  => (x -> PQ schema1 schema2 m y)
  -> PQ schema0 schema1 m x
  -> PQ schema0 schema2 m y
pqBind f (PQ x) = PQ $ \ conn -> do
  (x', conn') <- x conn
  runPQ (f x') conn'

pqThen
  :: Monad m
  => PQ schema1 schema2 m y
  -> PQ schema0 schema1 m x
  -> PQ schema0 schema2 m y
pqThen pq2 pq1 = pq1 & pqBind (\ _ -> pq2)

define
  :: MonadBase IO io
  => Definition schema0 schema1
  -> PQ schema0 schema1 io (Result '[])
define (UnsafeDefinition q) = PQ $ \ (Connection conn) -> do
  resultMaybe <- liftBase $ LibPQ.exec conn q
  case resultMaybe of
    Nothing -> error
      "define: LibPQ.exec returned no results"
    Just result -> return (Result result, Connection conn)

pqThenDefine
  :: MonadBase IO io
  => Definition schema1 schema2
  -> PQ schema0 schema1 io x
  -> PQ schema0 schema2 io (Result '[])
pqThenDefine = pqThen . define

class Monad pq => MonadPQ schema pq | pq -> schema where

  manipulateParams
    :: ToParams x params
    => Manipulation schema params ys -> x -> pq (Result ys)
  default manipulateParams
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => ToParams x params
    => Manipulation schema params ys -> x -> pq (Result ys)
  manipulateParams manipulation params = lift $
    manipulateParams manipulation params

  manipulate :: Manipulation schema '[] ys -> pq (Result ys)
  manipulate statement = manipulateParams statement ()

  queryParams
    :: ToParams x params
    => Query schema params ys -> x -> pq (Result ys)
  queryParams = manipulateParams . queryStatement

  query :: Query schema '[] ys -> pq (Result ys)
  query q = queryParams q ()

  traversePrepared
    :: (ToParams x params, Traversable list)
    => Manipulation schema params ys -> list x -> pq (list (Result ys))
  default traversePrepared
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => (ToParams x params, Traversable list)
    => Manipulation schema params ys -> list x -> pq (list (Result ys))
  traversePrepared manipulation params = lift $
    traversePrepared manipulation params

  forPrepared
    :: (ToParams x params, Traversable list)
    => list x -> Manipulation schema params ys -> pq (list (Result ys))
  forPrepared = flip traversePrepared

  traversePrepared_
    :: (ToParams x params, Foldable list)
    => Manipulation schema params ys -> list x -> pq ()
  default traversePrepared_
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => (ToParams x params, Foldable list)
    => Manipulation schema params ys -> list x -> pq ()
  traversePrepared_ manipulation params = lift $
    traversePrepared_ manipulation params

  forPrepared_
    :: (ToParams x params, Traversable list)
    => list x -> Manipulation schema params ys -> pq ()
  forPrepared_ = flip traversePrepared_

  liftPQ :: (LibPQ.Connection -> IO a) -> pq a
  default liftPQ
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => (LibPQ.Connection -> IO a) -> pq a
  liftPQ = lift . liftPQ

instance MonadBase IO io => MonadPQ schema (PQ schema schema io) where

  manipulateParams
    (UnsafeManipulation q :: Manipulation schema ps ys) (params :: x) =
      PQ $ \ (Connection conn) -> do
        let
          toParam' bytes = (LibPQ.invalidOid,bytes,LibPQ.Binary)
          params' = fmap (fmap toParam') (hcollapse (toParams @x @ps params))
        resultMaybe <- liftBase $ LibPQ.execParams conn q params' LibPQ.Binary
        case resultMaybe of
          Nothing -> error
            "manipulateParams: LibPQ.execParams returned no results"
          Just result -> return (Result result, Connection conn)

  traversePrepared
    (UnsafeManipulation q :: Manipulation schema xs ys) (list :: list x) =
      PQ $ \ (Connection conn) -> do
        let temp = "temporary_statement"
        prepResultMaybe <- liftBase $ LibPQ.prepare conn temp q Nothing
        case prepResultMaybe of
          Nothing -> error
            "traversePrepared: LibPQ.prepare returned no results"
          Just _prepResult -> return () -- todo: check status of prepResult
        results <- for list $ \ params -> do
          let
            toParam' bytes = (bytes,LibPQ.Binary)
            params' = fmap (fmap toParam') (hcollapse (toParams @x @xs params))
          resultMaybe <- liftBase $
            LibPQ.execPrepared conn temp params' LibPQ.Binary
          case resultMaybe of
            Nothing -> error
              "traversePrepared: LibPQ.execParams returned no results"
            Just result -> return $ Result result
        deallocResultMaybe <- liftBase $
          LibPQ.exec conn ("DEALLOCATE " <> temp <> ";")
        case deallocResultMaybe of
          Nothing -> error
            "traversePrepared: LibPQ.exec DEALLOCATE returned no results"
          Just _deallocResult -> return ()
          -- todo: check status of deallocResult
        return (results, Connection conn)

  traversePrepared_
    (UnsafeManipulation q :: Manipulation schema xs ys) (list :: list x) =
      PQ $ \ (Connection conn) -> do
        let temp = "temporary_statement"
        prepResultMaybe <- liftBase $ LibPQ.prepare conn temp q Nothing
        case prepResultMaybe of
          Nothing -> error
            "traversePrepared_: LibPQ.prepare returned no results"
          Just _prepResult -> return () -- todo: check status of prepResult
        for_ list $ \ params -> do
          let
            toParam' bytes = (bytes,LibPQ.Binary)
            params' = fmap (fmap toParam') (hcollapse (toParams @x @xs params))
          resultMaybe <- liftBase $
            LibPQ.execPrepared conn temp params' LibPQ.Binary
          case resultMaybe of
            Nothing -> error
              "traversePrepared_: LibPQ.execParams returned no results"
            Just _result -> return ()
        deallocResultMaybe <- liftBase $
          LibPQ.exec conn ("DEALLOCATE " <> temp <> ";")
        case deallocResultMaybe of
          Nothing -> error
            "traversePrepared: LibPQ.exec DEALLOCATE returned no results"
          Just _deallocResult -> return ()
          -- todo: check status of deallocResult
        return ((), Connection conn)

  liftPQ pq = PQ $ \ (Connection conn) -> do
    y <- liftBase $ pq conn
    return (y, Connection conn)

instance Monad m => Applicative (PQ schema schema m) where
  pure x = PQ $ \ conn -> pure (x, conn)
  (<*>) = pqAp

instance Monad m => Monad (PQ schema schema m) where
  return = pure
  (>>=) = flip pqBind

instance MonadTrans (PQ schema schema) where
  lift m = PQ $ \ conn -> do
    x <- m
    return (x, conn)

instance MonadBase b m => MonadBase b (PQ schema schema m) where
  liftBase = lift . liftBase

type PQRun schema =
  forall m x. Monad m => PQ schema schema m x -> m (x, Connection schema)

pqliftWith :: Functor m => (PQRun schema -> m a) -> PQ schema schema m a
pqliftWith f = PQ $ \ conn ->
  fmap (\ x -> (x, conn)) (f $ \ pq -> runPQ pq conn)

instance MonadBaseControl b m => MonadBaseControl b (PQ schema schema m) where
  type StM (PQ schema schema m) x = StM m (x, Connection schema)
  liftBaseWith f =
    pqliftWith $ \ run -> liftBaseWith $ \ runInBase -> f $ runInBase . run
  restoreM = PQ . const . restoreM

connectdb :: MonadBase IO io => ByteString -> io (Connection schema)
connectdb = fmap Connection . liftBase . LibPQ.connectdb

finish :: MonadBase IO io => Connection schema -> io ()
finish = liftBase . LibPQ.finish . unConnection

withConnection
  :: forall schema io x
   . MonadBaseControl IO io
  => ByteString
  -> (Connection schema -> io x)
  -> io x
withConnection connString = bracket (connectdb connString) finish

newtype Result (xs :: [(Symbol,ColumnType)])
  = Result { unResult :: LibPQ.Result }

newtype RowNumber = RowNumber { unRowNumber :: LibPQ.Row }

newtype ColumnNumber n cs c =
  UnsafeColumnNumber { getColumnNumber :: LibPQ.Column }

class KnownNat n => HasColumnNumber n columns column
  | n columns -> column where
  columnNumber :: ColumnNumber n columns column
  columnNumber =
    UnsafeColumnNumber . fromIntegral $ natVal' (proxy# :: Proxy# n)
instance {-# OVERLAPPING #-} HasColumnNumber 0 (column1:columns) column1
instance {-# OVERLAPPABLE #-}
  (KnownNat n, HasColumnNumber (n-1) columns column)
    => HasColumnNumber n (column' : columns) column

getValue
  :: (FromColumnValue colty y, MonadBase IO io)
  => RowNumber
  -> ColumnNumber n columns colty
  -> Result columns
  -> io y
getValue
  (RowNumber r)
  (UnsafeColumnNumber c :: ColumnNumber n columns colty)
  (Result result)
   = fmap (fromColumnValue @colty . K) $ liftBase $ do
      numRows <- LibPQ.ntuples result
      when (numRows < r) $ error $
        "getValue: expected at least " <> show r <> "rows but only saw "
        <> show numRows
      LibPQ.getvalue result r c

getRow
  :: (FromRow columns y, MonadBase IO io)
  => RowNumber -> Result columns -> io y
getRow (RowNumber r) (Result result :: Result columns) = liftBase $do
  numRows <- LibPQ.ntuples result
  when (numRows < r) $ error $
    "getRow: expected at least " <> show r <> "rows but only saw "
    <> show numRows
  let len = fromIntegral (lengthSList (Proxy @columns))
  numCols <- LibPQ.nfields result
  when (numCols /= len) $ error $
    "getRow: expected at least " <> show len <> "columns but only saw "
    <> show numCols
  row' <- traverse (LibPQ.getvalue result r) [0 .. len - 1]
  case fromList row' of
    Nothing -> error "getRow: found unexpected length"
    Just row -> return $ fromRow @columns row

nextRow
  :: (FromRow columns y, MonadBase IO io)
  => Result columns -> RowNumber -> io (Maybe (RowNumber,y))
nextRow (Result result :: Result columns) (RowNumber r) = liftBase $ do
  numRows <- LibPQ.ntuples result -- todo: cache this
  if numRows < r then return Nothing else do
    let len = fromIntegral (lengthSList (Proxy @columns))
    numCols <- LibPQ.nfields result -- todo: cache this
    when (numCols /= len) $ error $
      "nextRow: expected at least " <> show len <> "columns but only saw "
      <> show numCols
    row' <- traverse (LibPQ.getvalue result r) [0 .. len - 1]
    case fromList row' of
      Nothing -> error "nextRow: found unexpected length"
      Just row -> return $ Just (RowNumber (r+1), fromRow @columns row)

getRows :: (FromRow columns y, MonadBase IO io) => Result columns -> io [y]
getRows (Result result :: Result columns) = liftBase $ do
  let len = fromIntegral (lengthSList (Proxy @columns))
  numCols <- LibPQ.nfields result
  when (numCols /= len) $ error $
    "getRow: expected at least " <> show len <> "columns but only saw "
    <> show numCols
  numRows <- LibPQ.ntuples result
  for [0 .. numRows - 1] $ \ r -> do
    row' <- traverse (LibPQ.getvalue result r) [0 .. len - 1]
    case fromList row' of
      Nothing -> error "getRows: found unexpected length"
      Just row -> return $ fromRow @columns row

getRowMaybe
  :: (FromRow columns y, MonadBase IO io)
  => RowNumber -> Result columns -> io (Maybe y)
getRowMaybe (RowNumber r) (Result result :: Result columns) = liftBase $do
  numRows <- LibPQ.ntuples result
  if numRows < r then return Nothing else do
    let len = fromIntegral (lengthSList (Proxy @columns))
    numCols <- LibPQ.nfields result
    when (numCols /= len) $ error $
      "getRow: expected at least " <> show len <> "columns but only saw "
      <> show numCols
    row' <- traverse (LibPQ.getvalue result r) [0 .. len - 1]
    case fromList row' of
      Nothing -> error "getRow: found unexpected length"
      Just row -> return . Just $ fromRow @columns row

liftResult
  :: MonadBase IO io
  => (LibPQ.Result -> IO x)
  -> Result results -> io x
liftResult f (Result result) = liftBase $ f result