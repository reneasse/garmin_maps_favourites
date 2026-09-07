import Toybox.Lang;
using Toybox.System;

//! Debug logging. Compiled out of release builds entirely.
(:background)
module Log {

    (:debug :background)
    function d(msg as String) as Void {
        System.println(msg);
    }

    (:release :background)
    function d(msg as String) as Void {
    }
}
