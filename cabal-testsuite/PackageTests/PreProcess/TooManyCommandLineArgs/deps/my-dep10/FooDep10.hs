module FooDep10 (fooDep10) where

import FooDepDep01
import FooDepDep02
import FooDepDep03
import FooDepDep04
import FooDepDep05
import FooDepDep06
import FooDepDep07
import FooDepDep08
import FooDepDep09
import FooDepDep10

fooDep10 :: Int
fooDep10 = sum
  [ 10
  , fooDepDep01
  , fooDepDep02
  , fooDepDep03
  , fooDepDep04
  , fooDepDep05
  , fooDepDep06
  , fooDepDep07
  , fooDepDep08
  , fooDepDep09
  , fooDepDep10
  ]
