-- | Display game data on the screen and receive user input
-- using one of the available raw frontends and derived operations.
module Game.LambdaHack.Client.UI.Frontend
  ( -- * Connection types.
    FrontReq(..), ChanFrontend(..)
    -- * Re-exported part of the raw frontend
  , frontendName
    -- * A derived operation
  , startupF
  ) where

import Control.Concurrent
import qualified Control.Concurrent.STM as STM
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.Text.IO as T
import System.IO

import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.UI.Animation
import Game.LambdaHack.Client.UI.Frontend.Chosen
import Game.LambdaHack.Common.ClientOptions

data FrontReq =
    FrontNormalFrame {frontFrame :: !SingleFrame}
      -- ^ show a frame
  | FrontRunningFrame {frontFrame :: !SingleFrame}
      -- ^ show a frame in running mode (don't insert delay between frames)
  | FrontDelay
      -- ^ perform a single explicit delay
  | FrontKey {frontKM :: ![K.KM], frontFr :: !SingleFrame}
      -- ^ flush frames, possibly show fadeout/fadein and ask for a keypress
  | FrontSlides {frontClear :: ![K.KM], frontSlides :: ![SingleFrame]}
      -- ^ show a whole slideshow without interleaving with other clients
  | FrontAutoYes !Bool
      -- ^ set the frontend option for auto-answering prompts
  | FrontFinish
      -- ^ exit frontend loop

-- | Connection channel between a frontend and a client. Frontend acts
-- as a server, serving keys, when given frames to display.
data ChanFrontend = ChanFrontend
  { responseF :: !(STM.TQueue K.KM)
  , requestF  :: !(STM.TQueue FrontReq)
  }

startupF :: DebugModeCli
         -> (Maybe (MVar ()) -> (ChanFrontend -> IO ()) -> IO ())
         -> IO ()
startupF dbg cont =
  (if sfrontendNull dbg then nullStartup
   else if sfrontendStd dbg then stdStartup
        else chosenStartup) dbg $ \fs -> do
    cont (fescMVar fs) (loopFrontend fs)
    let debugPrint t = when (sdbgMsgCli dbg) $ do
          T.hPutStrLn stderr t
          hFlush stderr
    debugPrint "Server shuts down"

-- | Display a prompt, wait for any of the specified keys (for any key,
-- if the list is empty). Repeat if an unexpected key received.
promptGetKey :: RawFrontend -> [K.KM] -> SingleFrame -> IO K.KM
promptGetKey fs [] frame = fpromptGetKey fs frame
promptGetKey fs keys frame = do
  km <- fpromptGetKey fs frame
  if km `elem` keys
    then return km
    else promptGetKey fs keys frame

getConfirmGeneric :: Bool -> RawFrontend -> [K.KM] -> SingleFrame
                  -> IO (Maybe Bool)
getConfirmGeneric autoYes fs clearKeys frame = do
  let DebugModeCli{sdisableAutoYes} = fdebugCli fs
  if autoYes && not sdisableAutoYes then do
    fdisplay fs True (Just frame)
    return $ Just True
  else do
    let extraKeys = [K.spaceKM, K.escKM, K.pgupKM, K.pgdnKM]
    km <- promptGetKey fs (clearKeys ++ extraKeys) frame
    return $! if km == K.escKM
              then Nothing
              else if km == K.pgupKM
                   then Just False
                   else Just True

-- Read UI requests from the client and send them to the frontend,
loopFrontend :: RawFrontend -> ChanFrontend -> IO ()
loopFrontend fs ChanFrontend{..} = loop False
 where
  writeKM :: K.KM -> IO ()
  writeKM km = STM.atomically $ STM.writeTQueue responseF km

  loop :: Bool -> IO ()
  loop autoYes = do
    efr <- STM.atomically $ STM.readTQueue requestF
    case efr of
      FrontNormalFrame{..} -> do
        fdisplay fs False (Just frontFrame)
        loop autoYes
      FrontRunningFrame{..} -> do
        fdisplay fs True (Just frontFrame)
        loop autoYes
      FrontDelay -> do
        fdisplay fs False Nothing
        loop autoYes
      FrontKey{..} -> do
        km <- promptGetKey fs frontKM frontFr
        writeKM km
        loop autoYes
      FrontSlides{frontSlides = []} -> do
        -- Hack.
        fsyncFrames fs
        writeKM K.spaceKM
        loop autoYes
      FrontSlides{..} -> do
        let displayFrs frs srf =
              case frs of
                [] -> assert `failure` "null slides" `twith` frs
                [x] -> do
                  fdisplay fs False (Just x)
                  writeKM K.spaceKM
                x : xs -> do
                  go <- getConfirmGeneric autoYes fs frontClear x
                  case go of
                    Nothing -> writeKM K.escKM
                    Just True -> displayFrs xs (x : srf)
                    Just False -> case srf of
                      [] -> displayFrs frs srf
                      y : ys -> displayFrs (y : frs) ys
        displayFrs frontSlides []
        loop autoYes
      FrontAutoYes b ->
        loop b
      FrontFinish ->
        return ()
        -- Do not loop again.
