package libsci;

import org.graalvm.nativeimage.c.function.CFunctionPointer;
import org.graalvm.nativeimage.c.function.InvokeCFunctionPointer;
import org.graalvm.nativeimage.c.type.CCharPointer;

/** Host callback function pointer interface.
 *
 *  Wraps a raw C function pointer that receives JSON-encoded arguments
 *  and returns a JSON-encoded result. The @InvokeCFunctionPointer
 *  annotation generates a direct call trampoline at build time. */
public interface LibsciHostFn extends CFunctionPointer {
    @InvokeCFunctionPointer
    CCharPointer invoke(CCharPointer jsonArgs);
}
