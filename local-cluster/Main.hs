{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}

module Main (main) where

import Cardano.Launcher.Node (CardanoNodeConn, nodeSocketFile)
import Cardano.Ledger.Slot (EpochSize (EpochSize))
import Control.Applicative (optional, (<**>), (<|>))
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (MonadReader (ask), ReaderT (ReaderT), lift)
import Data.Aeson (FromJSON, ToJSON, encodeFile)
import Data.Default (def)
import Data.Text (Text, unpack)
import Data.Time (NominalDiffTime)
import GHC.Conc (TVar, threadDelay)
import GHC.Generics (Generic)
import GHC.Natural (Natural)
import GHC.Word (Word64)
import Numeric.Positive (Positive)
import Options.Applicative (Parser, helper, info)
import Options.Applicative qualified as Options
import System.Posix (Handler (CatchOnce), installHandler, sigINT)
import Test.Plutip.Config
  ( ChainIndexMode (CustomPort, DefaultPort, NotNeeded),
    PlutipConfig (chainIndexMode, clusterWorkingDir, extraConfig),
    WorkingDirectory (Fixed, Temporary),
  )
import Test.Plutip.Internal.BotPlutusInterface.Wallet
  ( BpiWallet,
    cardanoMainnetAddress,
    mkMainnetAddress,
    walletPkh, addMnemonicWallet
  )
import Test.Plutip.Internal.Cluster.Extra.Types
  ( ExtraConfig (ExtraConfig),
  )
import Test.Plutip.Internal.LocalCluster
  ( ClusterStatus,
    startCluster,
    stopCluster,
  )
import Test.Plutip.Internal.Types (nodeSocket)
import Test.Plutip.Tools.CardanoApi (awaitAddressFunded)

main :: IO ()
main = do
  config <- Options.execParser (info (pClusterConfig <**> helper) mempty)
  case totalAmount config of
    Left e -> error e
    Right amt -> do
      let ClusterConfig {workDir, slotLength, epochSize, cIndexMode} = config
          workingDir = maybe Temporary (`Fixed` False) workDir

          extraConf = ExtraConfig slotLength epochSize
          plutipConfig = def {clusterWorkingDir = workingDir, extraConfig = extraConf, chainIndexMode = cIndexMode}

      putStrLn "Starting cluster..."
      (st, _) <- startCluster plutipConfig $ do
        w <- addMnemonicWallet (mnemonics config) [amt]
        liftIO $ putStrLn "Waiting for wallets to be funded..."
        awaitFunds [w] slotLength

        separate
        liftIO $ putStrLn $ "Mnemoncs: " <> unpack (mnemonics config)
        liftIO $ printWallet w
        printNodeRelatedInfo
        separate

        forM_ (dumpInfo config) $ \dInfo -> do
          cEnv <- ask
          lift $
            dumpClusterInfo
              dInfo
              (nodeSocket cEnv)
              [w]

      void $ installHandler sigINT (termHandler st) Nothing
      putStrLn "Cluster is running. Ctrl-C to stop."
      loopThreadDelay
  where
    loopThreadDelay = threadDelay 100000000 >> loopThreadDelay

    printNodeRelatedInfo = ReaderT $ \cEnv -> do
      putStrLn $ "Node socket: " <> show (nodeSocket cEnv)

    separate = liftIO $ putStrLn "\n------------\n"

    totalAmount :: ClusterConfig -> Either String Positive
    totalAmount cwc =
      case toAda (adaAmount cwc) + lvlAmount cwc of
        0 -> Left "One of --ada or --lovelace arguments should not be 0"
        amt -> Right $ fromInteger . toInteger $ amt

    dumpClusterInfo :: FilePath -> CardanoNodeConn -> [BpiWallet] -> IO ()
    dumpClusterInfo fp nodeConn ws = do
      encodeFile
        fp
        ( ClusterInfo
            { ciWallets = [(show . walletPkh $ w, show . mkMainnetAddress $ w) | w <- ws],
              ciNodeSocket = nodeSocketFile nodeConn
            }
        )

    printWallet w = do
      putStrLn $ "Wallet PKH: " ++ show (walletPkh w)
      putStrLn $ "Wallet mainnet address: " ++ show (mkMainnetAddress w)

    toAda = (* 1_000_000)

    -- waits for the last wallet to be funded
    awaitFunds ws delay = do
      let lastWallet = last ws
      liftIO $ putStrLn "Waiting till all wallets will be funded..."
      awaitAddressFunded (cardanoMainnetAddress lastWallet) delay

termHandler :: TVar (ClusterStatus ()) -> System.Posix.Handler
termHandler st = CatchOnce $ do
  putStrLn "Caught SIGTERM, stopping cluster"
  stopCluster st

data ClusterInfo = ClusterInfo
  { ciWallets :: [(String, String)],
    ciNodeSocket :: String
  }
  deriving (Show, Generic, ToJSON, FromJSON)

pMnemonics :: Parser Text
pMnemonics =
  Options.strOption
    ( Options.long "mnemonics"
        <> Options.short 'm'
        <> Options.metavar "MNEMONICS"
    )

padaAmount :: Parser Natural
padaAmount =
  Options.option
    Options.auto
    ( Options.long "ada"
        <> Options.short 'a'
        <> Options.metavar "ADA"
        <> Options.value 10_000
    )

plvlAmount :: Parser Natural
plvlAmount =
  Options.option
    Options.auto
    ( Options.long "lovelace"
        <> Options.short 'l'
        <> Options.metavar "Lovelace"
        <> Options.value 0
    )

pWorkDir :: Parser (Maybe FilePath)
pWorkDir =
  optional $
    Options.strOption
      ( Options.long "working-dir"
          <> Options.short 'w'
          <> Options.metavar "FILEPATH"
      )

pSlotLen :: Parser NominalDiffTime
pSlotLen =
  Options.option
    Options.auto
    ( Options.long "slot-len"
        <> Options.short 's'
        <> Options.metavar "SLOT_LEN"
        <> Options.value 0.2
    )

pEpochSize :: Parser EpochSize
pEpochSize =
  EpochSize <$> wordParser
  where
    wordParser :: Parser Word64
    wordParser =
      Options.option
        Options.auto
        ( Options.long "epoch-size"
            <> Options.short 'e'
            <> Options.metavar "EPOCH_SIZE"
            <> Options.value 160
        )

pChainIndexMode :: Parser ChainIndexMode
pChainIndexMode =
  noIndex <|> withIndexPort <|> pure DefaultPort
  where
    noIndex =
      Options.flag'
        NotNeeded
        ( Options.long "no-index"
            <> Options.help "Start cluster with chain-index on default port"
        )
    withIndexPort = CustomPort <$> portParser

    portParser =
      Options.option
        Options.auto
        ( Options.long "chain-index-port"
            <> Options.metavar "PORT"
            <> Options.help "Start cluster with chain-index on custom port"
        )

pInfoJson :: Parser (Maybe FilePath)
pInfoJson =
  optional $
    Options.strOption
      ( Options.long "dump-info-json"
          <> Options.metavar "FILEPATH"
          <> Options.help "After starting the cluster, add some useful runtime information to a JSON file (wallets, node socket path etc)"
          <> Options.value "local-cluster-info.json"
      )

pClusterConfig :: Parser ClusterConfig
pClusterConfig =
  ClusterConfig
    <$> pMnemonics
    <*> padaAmount
    <*> plvlAmount
    <*> pWorkDir
    <*> pSlotLen
    <*> pEpochSize
    <*> pChainIndexMode
    <*> pInfoJson

-- | Basic info about the cluster, to
-- be used by the command-line
data ClusterConfig = ClusterConfig
  { mnemonics :: Text,
    adaAmount :: Natural,
    lvlAmount :: Natural,
    workDir :: Maybe FilePath,
    slotLength :: NominalDiffTime,
    epochSize :: EpochSize,
    cIndexMode :: ChainIndexMode,
    dumpInfo :: Maybe FilePath
  }
  deriving stock (Show, Eq)
