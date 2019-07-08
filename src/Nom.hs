{-# language
        BangPatterns
      , BinaryLiterals
      , GADTs
      , LambdaCase
      , MagicHash
      , MultiWayIf
      , RankNTypes
      , ScopedTypeVariables
      , TypeApplications
      , TypeFamilies
      , TypeInType
      , TypeOperators
      , UnboxedSums
      , UnboxedTuples
  #-}

module Nom
  ( Parser(..)
  , StatefulParser(..)
  , Result(..)
  , run
  , bigEndianWord8
  , bigEndianWord16
  , bigEndianWord32
  , bigEndianWord64
  , decimalWord32
  , replicateStashIndex
  , replicate
  , take
  , mutate
  , consume
  , stash
  , byte
  , peek
  , optionalByte
  --, bytes
  , any
  , endOfLine
  , endOfInput
  , skipSpace
  --, takeBytesWhileMember
  --, takeBytesUntilByteConsume
  --, takeBytesUntilMemberConsume
  --, takeBytesUntilEndOfLineConsume
  ) where

import Prelude hiding (replicate,take,any)

import Data.Bytes.Types (Bytes(..))
--import Packed.Bytes.Set (ByteSet)
import Control.Monad.ST (runST)
import Data.Primitive (ByteArray(..),Array,MutableArray)
import GHC.Exts
import GHC.ST (ST(..))
import GHC.Word
import qualified Data.Primitive as PM

type Maybe# (a :: TYPE r) = (# (# #) | a #)
type Either# a (b :: TYPE r) = (# a | b #)

type Result# e (r :: RuntimeRep) (a :: TYPE r) =
  (# Int# , Either# e a #)

-- | The result of running a parser.
data Result e a = Result
  { resultIndex :: !Int -- ^ the index into the bytearray we ended on.
  , resultValue :: !(Either e a) -- ^ either an error, or a value parsed.
  } deriving (Eq,Show)

-- | Run a parser.
run :: ()
  => Bytes -- ^ Input bytearray
  -> Parser e a -- ^ Parser
  -> Result e a -- ^ Result
run (Bytes (ByteArray arr) (I# off) (I# len)) (Parser (ParserLevity f)) = case f arr off (off +# len) of
  (# ix, r #) -> case r of
    (# e | #) -> Result (I# (ix -# off)) (Left e)
    (# | a #) -> Result (I# (ix -# off)) (Right a)

-- | A Parser of values of type @a@, with potential for failure
--   with errors of type @e@.
newtype Parser e a = Parser { getParser :: ParserLevity e 'LiftedRep a }

{-
-- A parser that always consumes the same amount of input. It may, however,
-- fail even if the necessary amount of input is present.
data PossibleParser e a = PossibleParser
  Int#
  ( Int# -> e )
  ( ByteArray# -> Int# -> (# e | a #) )
-}

-- A parser that always consumes the same amount of input. Additionally,
-- it will always succeed if that amount of input is present.
data FixedParser e a = FixedParser
  Int# -- how many bytes do we need
  ( Int# -> e ) -- convert the actual number of bytes into an error
  -- convert the actual number of bytes into the number of
  -- bytes actually consumed (should be less than the argument given it)
  ( ByteArray# -> Int# -> a )

data FixedStatefulParser e s a = FixedStatefulParser
  Int# -- how many bytes do we need
  ( Int# -> ByteArray# -> Int# -> State# s -> (# State# s, (# e, Int# #) #) )
  -- convert the actual number of bytes into an error and a
  -- number of bytes consumed. The first argument to this function is
  -- the actual number of bytes. The second is the bytearray, and the
  -- third is the offset.
  ( ByteArray# -> Int# -> State# s -> (# State# s, a #) )

data FixedStashParser e s =
  forall a. FixedStashParser (FixedParser e a) (a -> ST s ())

newtype ParserLevity e (r :: RuntimeRep) (a :: TYPE r) = ParserLevity
  { getParserLevity ::
       ByteArray# -- input
    -> Int# -- offset
    -> Int# -- end (not length)
    -> Result# e r a
  }

-- | A parser that can interleave arbitrary 'ST' effects with parsing.
newtype StatefulParser e s a = StatefulParser
  { getStatefulParser ::
       ByteArray# -- input
    -> Int# -- offset
    -> Int# -- end (not length)
    -> State# s
    -> (# State# s, Result# e 'LiftedRep a #)
  }

{-
fmapPossibleParser :: (a -> b) -> PossibleParser e a -> PossibleParser e b
fmapPossibleParser f (PossibleParser n toError g) = PossibleParser n toError
  (\arr off -> case g arr off of
    (# e | #) -> (# e | #)
    (# | a #) -> (# | f a #)
  )
-}

fmapFixedParser :: (a -> b) -> FixedParser e a -> FixedParser e b
fmapFixedParser f (FixedParser n toError g) =
  FixedParser n toError (\arr off -> f (g arr off))

{-# INLINE fmapParser #-}
fmapParser :: (a -> b) -> Parser e a -> Parser e b
fmapParser f (Parser (ParserLevity g)) = Parser $ ParserLevity $ \arr off0 end -> case g arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# e | #) #)
    (# | a #) -> (# off1, (# | f a #) #)

mapParserError :: (c -> e) -> Parser c a -> Parser e a
mapParserError f (Parser (ParserLevity g)) = Parser $ ParserLevity $ \arr off0 end -> case g arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# f e | #) #)
    (# | a #) -> (# off1, (# | a #) #)

instance Functor (Parser e) where
  {-# INLINE fmap #-}
  -- This is written this way to improve the likelihood that the applicative
  -- rewrite rules fire.
  fmap f p = applyParser (pureParser f) p

instance Applicative (Parser e) where
  pure = pureParser
  {-# INLINE pure #-}
  (<*>) = applyParser
  {-# INLINE (<*>) #-}
  (*>) = sequenceRightParser
  {-# INLINE (*>) #-}

instance Monad (Parser e) where
  (>>=) = bindParser
  {-# INLINE (>>=) #-}

instance Functor (StatefulParser s e) where
  fmap f p = applyStatefulParser (pureStatefulParser f) p

instance Applicative (StatefulParser s e) where
  pure = pureStatefulParser
  {-# INLINE pure #-}
  (<*>) = applyStatefulParser
  {-# INLINE (<*>) #-}
  (<*) = sequenceLeftStatefulParser
  {-# INLINE (<*) #-}
  (*>) = sequenceRightStatefulParser
  {-# INLINE (*>) #-}

instance Monad (StatefulParser s e) where
  (>>=) = bindStatefulParser
  {-# INLINE (>>=) #-}


{-# NOINLINE[1] fixedParserToParser #-}
fixedParserToParser :: FixedParser e a -> Parser e a
fixedParserToParser (FixedParser n toError f) = Parser $ ParserLevity $ \arr off end ->
  let len = end -# off
   in case len >=# n of
        1# -> (# off +# n, (# | f arr off #) #)
        _ -> (# end, (# toError len | #) #)

{-# NOINLINE[1] fixedStatefulParserToStatefulParser #-}
fixedStatefulParserToStatefulParser :: FixedStatefulParser e s a -> StatefulParser e s a
fixedStatefulParserToStatefulParser = error "Uhoenuthantoehunt"

{-# NOINLINE[1] fixedStashParserToStatefulParser #-}
fixedStashParserToStatefulParser :: FixedStashParser e s -> StatefulParser e s ()
fixedStashParserToStatefulParser (FixedStashParser p f) =
  consume (fixedParserToParser p) >>= mutate . f

endOfLine :: e -> Parser e ()
-- TODO: use a bounded size parser for this.
endOfLine e = do
  w <- any e
  case w of
    10 -> pure ()
    13 -> byte e 10
    _ -> failure e

byte :: e -> Word8 -> Parser e ()
-- TODO: use a bounded size parser for this.
byte e (W8# w) = Parser $ ParserLevity $ \arr off end ->
  case end ># off of
    1# -> case eqWord# (indexWord8Array# arr off) w of
      1# -> (# off +# 1#, (# | () #) #)
      _ -> (# off, (# e | #) #)
    _ -> (# end, (# e | #) #)

peek :: e -> Parser e Word8
peek e = Parser $ ParserLevity $ \arr off end ->
  case end ># off of
    1# -> (# off, (# | W8# (indexWord8Array# arr off) #) #)
    _ -> (# end, (# e | #) #)

optionalByte :: Word8 -> Parser e Bool
-- TODO: use a bounded size parser for this.
optionalByte (W8# w) = Parser $ ParserLevity $ \arr off end ->
  case end ># off of
    1# -> (# off +# 1#, (# | isTrue# (eqWord# (indexWord8Array# arr off) w) #) #)
    _ -> (# end, (# | False #) #)

endOfInput :: e -> Parser e ()
-- TODO: It might be possible to use a bounded size parser
-- for this. But it might not since it needs the end index.
endOfInput e = Parser $ ParserLevity $ \_ off end ->
  case end ==# off of
    1# -> (# off, (# | () #) #)
    _ -> (# off, (# e | #) #)


failure :: e -> Parser e a
failure e = Parser $ ParserLevity $ \_ off _ -> (# off, (# e | #) #)

{-
takeBytesUntilByteConsume :: e -> Word8 -> Parser e Bytes
takeBytesUntilByteConsume e (W8# w) = Parser $ ParserLevity $ \arr off end -> case BAW.findByte' off (end -# off) w arr of
  (# | ix #) -> (# ix +# 1#, (# | Bytes (ByteArray arr) (I# off) (I# (ix -# off)) #) #)
  (# (# #) | #) -> (# end, (# e | #) #)

takeBytesUntilMemberConsume :: e -> ByteSet -> Parser e (Bytes,Word8)
takeBytesUntilMemberConsume e b = Parser $ ParserLevity $ \arr off end -> case BAW.findMemberByte (I# off) (I# (end -# off)) b (ByteArray arr) of
  Just (I# ix, W8# w) -> (# ix +# 1#, (# | (Bytes (ByteArray arr) (I# off) (I# (ix -# off)), W8# w) #) #)
  Nothing -> (# end, (# e | #) #)
-}

skipSpace :: Parser e ()
skipSpace = Parser $ ParserLevity $ \arr off end -> case findNonAsciiSpace (I# off) (I# (end -# off)) (ByteArray arr) of
  (# | ix #) -> (# ix, (# | () #) #)
  (# (# #) | #) -> (# end, (# | () #) #)

{-
takeBytesWhileMember :: ByteSet -> Parser e Bytes
takeBytesWhileMember b = Parser $ ParserLevity $ \arr off end -> case BAW.findNonMemberByte (I# off) (I# (end -# off)) b (ByteArray arr) of
  Just (I# ix, !_) -> (# ix, (# | (Bytes (ByteArray arr) (I# off) (I# (ix -# off))) #) #)
  Nothing -> (# end, (# | Bytes (ByteArray arr) (I# off) (I# (end -# off)) #) #)
-}

{-
takeBytesUntilEndOfLineConsume :: e -> Parser e Bytes
takeBytesUntilEndOfLineConsume e = Parser $ ParserLevity $ \arr off end ->
  case BAW.findAnyByte2 (I# off) (I# (end -# off)) 10 13 (ByteArray arr) of
    Nothing -> (# end, (# e | #) #)
    Just (I# ix, theByte) -> case theByte of
      10 -> (# ix +# 1#, (# | Bytes (ByteArray arr) (I# off) (I# (ix -# off)) #) #)
      _ -> case ix <# end of
        1# -> case eqWord# (indexWord8Array# arr ix) 10## of
          1# -> (# ix +# 2#, (# | (Bytes (ByteArray arr) (I# off) (I# (ix -# off))) #) #)
          _ -> (# ix +# 2#, (# e | #) #)
        _ -> (# end, (# e | #) #)

take :: e -> Int -> Parser e Bytes
-- consider rewriting this as a fixed parser
take e (I# n# ) = Parser $ ParserLevity $ \arr off end -> case (end -# off) >=# n# of
  1# -> (# off +# n#, (# | Bytes (PM.ByteArray arr) (I# off) (I# n#) #) #)
  _ -> (# end, (# e | #) #)
-}

take :: e -> Int -> Parser e Bytes
take e = fixedParserToParser . fixedTake e
{-# inline take #-}

fixedTake :: e -> Int -> FixedParser e Bytes
fixedTake e (I# i#) = FixedParser i# (\_ -> e) $ \arr# off#
  -> Bytes (ByteArray arr#) (I# off#) (I# (i# -# off#))

{-# INLINE bigEndianWord64 #-}
bigEndianWord64 :: e -> Parser e Word64
bigEndianWord64 = fixedParserToParser . fixedBigEndianWord64

fixedBigEndianWord64 :: e -> FixedParser e Word64
fixedBigEndianWord64 e = FixedParser 8# (\_ -> e) (\arr off -> W64# (unsafeBigEndianWord64Unboxed arr off))

unsafeBigEndianWord64Unboxed :: ByteArray# -> Int# -> Word#
unsafeBigEndianWord64Unboxed arr off =
  let !byteA = indexWord8Array# arr off
      !byteB = indexWord8Array# arr (off +# 1#)
      !byteC = indexWord8Array# arr (off +# 2#)
      !byteD = indexWord8Array# arr (off +# 3#)
      !byteE = indexWord8Array# arr (off +# 4#)
      !theWord = uncheckedShiftL# byteA 32#
           `or#` uncheckedShiftL# byteB 24#
           `or#` uncheckedShiftL# byteC 16#
           `or#` uncheckedShiftL# byteD 8#
           `or#` byteE
   in theWord

{-# INLINE bigEndianWord32 #-}
bigEndianWord32 :: e -> Parser e Word32
bigEndianWord32 = fixedParserToParser . fixedBigEndianWord32

{-# INLINE fixedBigEndianWord32 #-}
fixedBigEndianWord32 :: e -> FixedParser e Word32
fixedBigEndianWord32 e = FixedParser 4# (\_ -> e) (\arr off -> W32# (unsafeBigEndianWord32Unboxed arr off))

unsafeBigEndianWord32Unboxed :: ByteArray# -> Int# -> Word#
unsafeBigEndianWord32Unboxed arr off =
  let !byteA = indexWord8Array# arr off
      !byteB = indexWord8Array# arr (off +# 1#)
      !byteC = indexWord8Array# arr (off +# 2#)
      !byteD = indexWord8Array# arr (off +# 3#)
      !theWord = uncheckedShiftL# byteA 24#
           `or#` uncheckedShiftL# byteB 16#
           `or#` uncheckedShiftL# byteC 8#
           `or#` byteD
   in theWord

{-# INLINE any #-}
any :: e -> Parser e Word8
any = fixedParserToParser . fixedAny

{-# INLINE fixedAny #-}
fixedAny :: e -> FixedParser e Word8
fixedAny e = FixedParser 1# (\_ -> e) (\arr off -> W8# (indexWord8Array# arr off))

{-# INLINE bigEndianWord16 #-}
bigEndianWord16 :: e -> Parser e Word16
bigEndianWord16 = fixedParserToParser . fixedBigEndianWord16

{-# INLINE fixedBigEndianWord16 #-}
fixedBigEndianWord16 :: e -> FixedParser e Word16
fixedBigEndianWord16 e = FixedParser 2# (\_ -> e) (\arr off -> W16# (unsafeBigEndianWord16Unboxed arr off))

bigEndianWord8 :: e -> Parser e Word8
bigEndianWord8 = fixedParserToParser . fixedBigEndianWord8

{-# INLINE fixedBigEndianWord8 #-}
fixedBigEndianWord8 :: e -> FixedParser e Word8
fixedBigEndianWord8 e = FixedParser 1# (\_ -> e) (\arr off -> W8# (unsafeBigEndianWord8Unboxed arr off))

unsafeBigEndianWord16Unboxed :: ByteArray# -> Int# -> Word#
unsafeBigEndianWord16Unboxed arr off =
  let !byteA = indexWord8Array# arr off
      !byteB = indexWord8Array# arr (off +# 1#)
      !theWord = uncheckedShiftL# byteA 8#
           `or#` byteB
   in theWord

unsafeBigEndianWord8Unboxed :: ByteArray# -> Int# -> Word#
unsafeBigEndianWord8Unboxed arr off =
  let !theWord = indexWord8Array# arr off
  in theWord

-- | This parser does not allow leading zeroes. Consequently,
-- we can establish an upper bound on the number of bytes this
-- parser will consume. This means that it can typically omit
-- most bounds-checking as it runs.
decimalWord32 :: e -> Parser e Word32
decimalWord32 e = Parser (boxWord32Parser (decimalWord32Unboxed e))
  -- atMost 10#
  -- unsafeDecimalWord32Unboxed
  -- (\x -> case decimalWord32Unboxed)

decimalWord32Unboxed :: forall e. e -> ParserLevity e 'WordRep Word#
decimalWord32Unboxed e = ParserLevity $ \arr off end -> let len = end -# off in case len ># 0# of
  1# -> case unsafeDecimalDigitUnboxedMaybe arr off of
    (# (# #) | #) -> (# off, (# e | #) #)
    (# | initialDigit #) -> case initialDigit of
      0## -> -- zero is special because we do not allow leading zeroes
        case len ># 1# of
          1# -> case unsafeDecimalDigitUnboxedMaybe arr (off +# 1#) of
            (# (# #) | #) -> (# off +# 1#, (# | 0## #) #)
            (# | _ #) -> (# (off +# 2#) , (# e | #) #)
          _ -> (# off +# 1#, (# | 0## #) #)
      _ ->
        let maximumDigits = case gtWord# initialDigit 4## of
              1# -> 8#
              _ -> 9#
            go :: Int# -> Int# -> Word# -> Result# e 'WordRep Word#
            go !ix !counter !acc = case counter ># 0# of
              1# -> case ix <# end of
                1# -> case unsafeDecimalDigitUnboxedMaybe arr ix of
                  (# (# #) | #) -> (# ix, (# | acc #) #)
                  (# | w #) -> go (ix +# 1#) (counter -# 1#) (plusWord# w (timesWord# acc 10##))
                _ -> (# ix, (# | acc #) #)
              _ -> let accTrimmed = acc `and#` 0xFFFFFFFF## in case ix <# end of
                1# -> case unsafeDecimalDigitUnboxedMaybe arr ix of
                  (# (# #) | #) -> case (ltWord# accTrimmed 1000000000##) `andI#` (eqWord# initialDigit 4##) of
                    1# -> (# ix, (# e | #) #)
                    _ -> (# ix, (# | accTrimmed #) #)
                  (# | _ #) -> (# ix, (# e | #) #)
                _ -> case (ltWord# accTrimmed 1000000000##) `andI#` (eqWord# initialDigit 4##) of
                  1# -> (# ix, (# e | #) #)
                  _ -> (# ix, (# | accTrimmed #) #)
         in go ( off +# 1# ) maximumDigits initialDigit
  _ -> (# off, (# e | #) #)

unsafeDecimalDigitUnboxedMaybe :: ByteArray# -> Int# -> Maybe# Word#
unsafeDecimalDigitUnboxedMaybe arr off =
  let !w = minusWord# (indexWord8Array# arr (off +# 0#)) 48##
   in case ltWord# w 10## of
        1# -> (# | w #)
        _ -> (# (# #) | #)

{-# INLINE applyFixedParser #-}
applyFixedParser :: FixedParser e (a -> b) -> FixedParser e a -> FixedParser e b
applyFixedParser (FixedParser n1 toError1 p1) (FixedParser n2 toError2 p2) =
  FixedParser (n1 +# n2)
    (\i -> case i <# n1 of
      1# -> toError1 i
      _ -> toError2 (n1 -# i)
    )
    (\arr off0 -> p1 arr off0 (p2 arr (off0 +# n1)))

{-# INLINE tupleFixedParsers #-}
tupleFixedParsers :: FixedParser e a -> FixedParser e b -> FixedParser e (a,b)
tupleFixedParsers (FixedParser n1 toError1 p1) (FixedParser n2 toError2 p2) =
  FixedParser (n1 +# n2)
    (\i -> case i <# n1 of
      1# -> toError1 i
      _ -> toError2 (n1 -# i)
    )
    (\arr off0 -> (p1 arr off0, p2 arr (off0 +# n1)))

{-# INLINE appendFixedStashParsers #-}
appendFixedStashParsers :: FixedStashParser e s -> FixedStashParser e s -> FixedStashParser e s
appendFixedStashParsers (FixedStashParser consumeA mutateA) (FixedStashParser consumeB mutateB) =
  FixedStashParser
    (tupleFixedParsers consumeA consumeB)
    (\(a,b) -> mutateA a *> mutateB b)

{-# RULES "parserApplyPure{Fixed}" [~2] forall f a. applyParser (pureParser f) (fixedParserToParser a) =
      fixedParserToParser (fmapFixedParser f a)
#-}
{-# RULES "parserApply{Fixed}" [~2] forall f a. applyParser (fixedParserToParser f) (fixedParserToParser a) =
      fixedParserToParser (applyFixedParser f a)
#-}
{-# RULES "parserApplyReassociate" [~2] forall f a b. applyParser (applyParser f (fixedParserToParser a)) (fixedParserToParser b) =
      applyParser
        (fmapParser uncurry f)
        (fixedParserToParser (tupleFixedParsers a b))
#-}
{-# RULES "parserApplyBindReassociate" [2] forall f a b. applyParser (fixedParserToParser a) (bindParser (fixedParserToParser b) f) =
      bindParser
        (fixedParserToParser (tupleFixedParsers a b))
        (\(g,y) -> fmapParser g (f y))
#-}
{-# RULES "stashSequenceRight" [~2] forall a b. sequenceRightStatefulParser (fixedStashParserToStatefulParser a) (fixedStashParserToStatefulParser b) =
      fixedStashParserToStatefulParser (appendFixedStashParsers a b)
#-}
{-# RULES "stashSequenceLeft" [~2] forall a b. sequenceLeftStatefulParser (fixedStashParserToStatefulParser a) (fixedStashParserToStatefulParser b) =
      fixedStashParserToStatefulParser (appendFixedStashParsers a b)
#-}

{-# NOINLINE[1] pureParser #-}
pureParser :: a -> Parser e a
pureParser a = Parser (ParserLevity (\_ off _ -> (# off, (# | a #) #)))

{-# NOINLINE[1] pureStatefulParser #-}
pureStatefulParser :: a -> StatefulParser e s a
pureStatefulParser a = StatefulParser (\_ off _ s0 -> (# s0, (# off, (# | a #) #) #))

{-# NOINLINE[1] applyParser #-}
applyParser :: Parser e (a -> b) -> Parser e a -> Parser e b
applyParser (Parser f) (Parser g) = Parser (applyLifted f g)

{-# NOINLINE[1] sequenceRightParser #-}
sequenceRightParser :: Parser e a -> Parser e b -> Parser e b
sequenceRightParser (Parser a) (Parser b) = Parser (liftedSequenceRight a b)

{-# NOINLINE[1] bindParser #-}
bindParser :: Parser e a -> (a -> Parser e b) -> Parser e b
bindParser (Parser a) f = Parser (bindLifted a (\x -> getParser (f x)))

{-# NOINLINE[1] boxWord32Parser #-}
boxWord32Parser ::
     ParserLevity e 'WordRep Word#
  -> ParserLevity e 'LiftedRep Word32
boxWord32Parser (ParserLevity f) = ParserLevity $ \arr off0 end -> case f arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# e | #) #)
    (# | w #) -> (# off1, (# | W32# w #) #)

{-# NOINLINE[1] applyStatefulParser #-}
applyStatefulParser ::
     StatefulParser e s (a -> b)
  -> StatefulParser e s a
  -> StatefulParser e s b
applyStatefulParser (StatefulParser f) (StatefulParser g) = StatefulParser $ \arr off0 end s0 -> case f arr off0 end s0 of
  (# s1, (# off1, r #) #) -> case r of
    (# e | #) -> (# s1, (# off1, (# e | #) #) #)
    (# | a #) -> case g arr off1 end s1 of
      (# s2, (# off2, r2 #) #) -> case r2 of
        (# e | #) -> (# s2, (# off2, (# e | #) #) #)
        (# | b #) -> (# s2, (# off2, (# | a b #) #) #)

{-# NOINLINE[1] sequenceLeftStatefulParser #-}
sequenceLeftStatefulParser ::
     StatefulParser e s a
  -> StatefulParser e s b
  -> StatefulParser e s a
sequenceLeftStatefulParser (StatefulParser f) (StatefulParser g) = StatefulParser $ \arr off0 end s0 -> case f arr off0 end s0 of
  (# s1, (# off1, r #) #) -> case r of
    (# e | #) -> (# s1, (# off1, (# e | #) #) #)
    (# | a #) -> case g arr off1 end s1 of
      (# s2, (# off2, r2 #) #) -> case r2 of
        (# e | #) -> (# s2, (# off2, (# e | #) #) #)
        (# | _ #) -> (# s2, (# off2, (# | a #) #) #)

{-# NOINLINE[1] sequenceRightStatefulParser #-}
sequenceRightStatefulParser ::
     StatefulParser e s a
  -> StatefulParser e s b
  -> StatefulParser e s b
sequenceRightStatefulParser (StatefulParser f) (StatefulParser g) = StatefulParser $ \arr off0 end s0 -> case f arr off0 end s0 of
  (# s1, (# off1, r #) #) -> case r of
    (# e | #) -> (# s1, (# off1, (# e | #) #) #)
    (# | _ #) -> case g arr off1 end s1 of
      (# s2, (# off2, r2 #) #) -> case r2 of
        (# e | #) -> (# s2, (# off2, (# e | #) #) #)
        (# | b #) -> (# s2, (# off2, (# | b #) #) #)

applyLifted ::
     ParserLevity e 'LiftedRep (a -> b)
  -> ParserLevity e 'LiftedRep a
  -> ParserLevity e 'LiftedRep b
applyLifted (ParserLevity f) (ParserLevity g) = ParserLevity $ \arr off0 end -> case f arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# e | #) #)
    (# | a #) -> case g arr off1 end of
      (# off2, r2 #) -> case r2 of
        (# e | #) -> (# off2, (# e | #) #)
        (# | b #) -> (# off2, (# | a b #) #)

liftedSequenceRight ::
     ParserLevity e 'LiftedRep a
  -> ParserLevity e 'LiftedRep b
  -> ParserLevity e 'LiftedRep b
liftedSequenceRight (ParserLevity f) (ParserLevity g) =
  ParserLevity $ \arr off0 end -> case f arr off0 end of
    (# off1, r #) -> case r of
      (# e | #) -> (# off1, (# e | #) #)
      (# | _ #) -> case g arr off1 end of
        (# off2, r2 #) -> case r2 of
          (# e | #) -> (# off2, (# e | #) #)
          (# | b #) -> (# off2, (# | b #) #)

bindLifted ::
     ParserLevity e 'LiftedRep a
  -> (a -> ParserLevity e 'LiftedRep b)
  -> ParserLevity e 'LiftedRep b
bindLifted (ParserLevity x) f = ParserLevity $ \arr off0 end -> case x arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# e | #) #)
    (# | a #) -> case getParserLevity (f a) arr off1 end of
      (# off2, r2 #) -> case r2 of
        (# e | #) -> (# off2, (# e | #) #)
        (# | b #) -> (# off2, (# | b #) #)

bindStatefulParser ::
     StatefulParser e s a
  -> (a -> StatefulParser e s b)
  -> StatefulParser e s b
bindStatefulParser (StatefulParser x) f =
  StatefulParser $ \arr off0 end s0 -> case x arr off0 end s0 of
    (# s1, (# off1, r #) #) -> case r of
      (# e | #) -> (# s1, (# off1, (# e | #) #) #)
      (# | a #) -> case getStatefulParser (f a) arr off1 end s1 of
        (# s2, (# off2, r2 #) #) -> case r2 of
          (# e | #) -> (# s2, (# off2, (# e | #) #) #)
          (# | b #) -> (# s2, (# off2, (# | b #) #) #)

-- | Lift a 'ST' action into a stateful parser.
mutate :: ST s a -> StatefulParser e s a
mutate (ST f) = StatefulParser $ \_ off _ s0 ->
  case f s0 of
    (# s1, a #) -> (# s1, (# off, (# | a #) #) #)

-- | Lift a pure parser into a stateful parser.
consume :: Parser e a -> StatefulParser e s a
consume (Parser (ParserLevity f)) = StatefulParser $ \arr off end s0 ->
  (# s0, f arr off end #)

-- | Run a parser and then feed its result into the @ST@ action. Note
-- that:
--
-- > stash p f = consume p >>= mutate . f
--
-- However, @stash@ is eligible for a few additional rewrite rules
-- and should be preferred when possible.
stash :: Parser e a -> (a -> ST s ()) -> StatefulParser e s ()
-- This might actually not be needed. Rethink this.
stash p f = consume p >>= mutate . f
{-# NOINLINE[1] stash #-}
{-# RULES "stash{Fixed}" [~2] forall p f. stash (fixedParserToParser p) f = fixedStashParserToStatefulParser (FixedStashParser p f) #-}

{-# NOINLINE[1] replicateStashIndex #-}
{-# RULES "replicateStashIndex{Fixed}" [~2] forall toErr n p save. replicateStashIndex toErr n (fixedParserToParser p) save =
   fixedStatefulParserToStatefulParser (replicateFixedStashIndex toErr n p save)
#-}
replicateStashIndex :: forall e c s a.
     (Int -> c -> e) -- ^ Turn the index into an error message
  -> Int -- ^ Number of times to run the parser
  -> Parser c a -- ^ Parser
  -> (Int -> a -> ST s ()) -- ^ Save the result of a successful parse
  -> StatefulParser e s ()
replicateStashIndex toErr n p save = go 0 where
  go !ix = if ix < n
    then (consume (mapParserError (toErr ix) p) >>= (mutate . save ix)) *> go (ix + 1)
    else pure ()

replicateFixedStashIndex :: forall e c s a.
     (Int -> c -> e) -- ^ Turn the index into an error message
  -> Int -- ^ Number of times to run the parser
  -> FixedParser c a -- ^ Parser
  -> (Int -> a -> ST s ()) -- ^ Save the result of a successful parse
  -> FixedStatefulParser e s ()
replicateFixedStashIndex castErr (I# n) (FixedParser sz toErr f) save =
  FixedStatefulParser (n *# sz)
    ( \len arr off s ->
      let !(# m, remaining #) = quotRemInt# len sz
          go !ix !off0 s0 = case ix <# m of
            1# -> case unST (save (I# ix) (f arr off0)) s0 of
              (# s1, _ #) -> go (ix +# 1#) (off0 +# sz) s1
            _ -> (# s0, (# castErr (I# ix) (toErr remaining), (len +# remaining) -# sz #) #)
       in go 0# off s
    )
    ( \arr off s ->
      let go !ix !off0 s0 = case ix <# n of
            1# -> case unST (save (I# ix) (f arr off0)) s0 of
              (# s1, _ #) -> go (ix +# 1#) (off0 +# sz) s1
            _ -> (# s0, () #)
       in go 0# off s
    )

{-# NOINLINE[1] replicate #-}
{-# RULES "replicate{Fixed}" [~2] forall n p. replicate n (fixedParserToParser p) =
   fixedParserToParser (replicateFixed n p)
#-}
replicate :: Int -> Parser e a -> Parser e (Array a)
replicate n p = go 0 [] where
  go ix !xs = if ix < n
    then do
      x <- p
      go (ix + 1) (x : xs)
    else return (reverseArrayFromListN n xs)

replicateFixed :: Int -> FixedParser e a -> FixedParser e (Array a)
replicateFixed (I# n) (FixedParser sz toErr f) =
  FixedParser (n *# sz)
    (\len -> toErr (remInt# len sz))
    (\arr off ->
      let go !ix !off0 !xs = case ix <# n of
            1# -> go (ix +# 1#) (off0 +# sz) (f arr off0 : xs)
            _ -> xs
       in reverseArrayFromListN (I# n) (go 0# off [])
    )

unST :: ST s a -> State# s -> (# State# s, a #)
unST (ST f) = f

-- Precondition: the first argument must be the length of the list.
reverseArrayFromListN :: Int -> [a] -> Array a
reverseArrayFromListN n l =
  createArray n errorThunk $ \mi ->
    let go !i (x:xs) = do
          PM.writeArray mi i x
          go (i - 1) xs
        go !_ [] = return ()
     in go (n - 1) l

{-# NOINLINE errorThunk #-}
errorThunk :: a
errorThunk = error "Packed.Bytes.Parser: error thunk forced"

createArray
  :: Int
  -> a
  -> (forall s. MutableArray s a -> ST s ())
  -> Array a
createArray n x f = runST $ do
  ma <- PM.newArray n x
  f ma
  PM.unsafeFreezeArray ma

unInt :: Int -> Int#
unInt (I# i) = i

findNonAsciiSpace :: Int -> Int -> ByteArray -> Maybe# Int#
findNonAsciiSpace !start !len !arr = go start (start + len) where
  go !ix !end = if ix < end
    then if isAsciiSpace (PM.indexByteArray arr ix)
      then go (ix + 1) end
      else (# | unInt ix #)
    else (# (# #) | #)

isAsciiSpace :: Word8 -> Bool
isAsciiSpace w = w == 32 || w - 9 <= 4
