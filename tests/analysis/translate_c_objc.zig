//! Patterns produced by translate-c for Objective-C classes and protocols.

const NSObjectProtocol = opaque {
    pub fn description(self: *NSObjectProtocol) ?*NSString {
        _ = self;
        return null;
    }
};

const NSString = opaque {
    pub fn length(self: *NSString) c_ulong {
        _ = self;
        return 0;
    }
    pub fn alloc() ?*NSString {
        return null;
    }
    pub inline fn as(self: *NSString, comptime T: type) *T {
        return @ptrCast(self);
    }
};

var string: *NSString = undefined;

const allocated = NSString.alloc();
//    ^^^^^^^^^ (?*NSString)()

const length = string.length();
//    ^^^^^^ (c_ulong)()

const as_method_call = string.as(NSObjectProtocol);
//    ^^^^^^^^^^^^^^ (*NSObjectProtocol)()

const as_function_call = NSString.as(string, NSObjectProtocol);
//    ^^^^^^^^^^^^^^^^ (*NSObjectProtocol)()

const description = string.as(NSObjectProtocol).description();
//    ^^^^^^^^^^^ (?*NSString)()

const ns = struct {
    const Protocol = NSObjectProtocol;
};

const as_field_access_arg = string.as(ns.Protocol);
//    ^^^^^^^^^^^^^^^^^^^ (*NSObjectProtocol)()
