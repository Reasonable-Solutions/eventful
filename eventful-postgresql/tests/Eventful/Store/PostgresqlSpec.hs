module Eventful.Store.PostgresqlSpec (spec) where

import Control.Monad.Reader (ask)
import Data.Monoid ((<>))
import Data.Text (Text, intercalate)
import Database.Persist.Postgresql
import Test.Hspec

import Eventful.Store.Postgresql
import Eventful.TestHelpers

makeStore :: (MonadIO m) => m (EventStore JSONString (SqlPersistT m), ConnectionPool)
makeStore = do
  -- TODO: Obviously this is hard-coded, make this use environment variables or
  -- something in the future.
  let
    connString = "host=localhost port=5432 user=postgres dbname=eventful_test password=password"
    store = postgresqlEventStore defaultSqlEventStoreConfig
  pool <- liftIO $ runNoLoggingT (createPostgresqlPool connString 1)
  initializePostgresqlEventStore pool
  liftIO $ runSqlPool truncateTables pool
  return (store, pool)

getTables :: MonadIO m => SqlPersistT m [Text]
getTables = do
    tables <-
      rawSql
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';"
      []
    return $ map unSingle tables

truncateTables :: MonadIO m => SqlPersistT m ()
truncateTables = do
    tables <- getTables
    sqlBackend <- ask
    let
      escapedTables = map (connEscapeName sqlBackend . DBName) tables
      query = "TRUNCATE TABLE " <> intercalate ", " escapedTables <> " RESTART IDENTITY CASCADE"
    rawExecute query []

makeGlobalStore
  :: (MonadIO m)
  => m (EventStore JSONString (SqlPersistT m), GloballyOrderedEventStore JSONString (SqlPersistT m), ConnectionPool)
makeGlobalStore = do
  (store, pool) <- makeStore
  return (store, sqlGloballyOrderedEventStore defaultSqlEventStoreConfig, pool)


spec :: Spec
spec = do
  describe "Postgresql event store" $ do
    eventStoreSpec makeStore (flip runSqlPool) jsonStringSerializer
    sequencedEventStoreSpec makeGlobalStore (flip runSqlPool) jsonStringSerializer
