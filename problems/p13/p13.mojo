from sys import sizeof
from testing import assert_equal
from gpu.host import DeviceContext

# ANCHOR: axis_sum
from gpu import thread_idx, block_idx, block_dim, barrier
from layout import Layout, LayoutTensor
from layout.tensor_builder import LayoutTensorBuild as tb


alias TPB = 8
alias NROWS = 4
alias SIZE = 6
alias BLOCKS_PER_GRID = (1, NROWS)
alias THREADS_PER_BLOCK = (TPB, 1)
alias dtype = DType.float32
alias in_layout = Layout.row_major(NROWS, SIZE)
alias out_layout = Layout.row_major(NROWS, 1)


fn axis_sum[
    in_layout: Layout, out_layout: Layout
](
    output: LayoutTensor[mut=False, dtype, out_layout],
    a: LayoutTensor[mut=False, dtype, in_layout],
    size: Int,
):
    global_i = block_dim.x * block_idx.x + thread_idx.x
    local_i = thread_idx.x
    row = block_idx.y
    # FILL ME IN (roughly 15 lines)

    # allocate a tensor in shared memory
    cache = tb[dtype]().row_major[TPB]().shared().alloc()

    # Visualize:
    # Block(0,0): [T0,T1,T2,T3,T4,T5,T6,T7] -> Row 0: [ 0, 1, 2, 3, 4, 5]
    # Block(0,1): [T0,T1,T2,T3,T4,T5,T6,T7] -> Row 1: [ 6, 7, 8, 9,10,11]
    # Block(0,2): [T0,T1,T2,T3,T4,T5,T6,T7] -> Row 2: [12,13,14,15,16,17]
    # Block(0,3): [T0,T1,T2,T3,T4,T5,T6,T7] -> Row 3: [18,19,20,21,22,23]

    # load data into shared memory
    # each row is handled by one block bc we have grid_dim=(1, NROWS)
    if local_i < size:
        cache[local_i] = a[row, local_i]
    else:
        cache[local_i] = 0
    barrier()

    # do parallel reduction within each row
    stride = TPB // 2
    while stride > 0:
        # read phase, read values then synchronize to avoid race conditions
        var temp_val: output.element_type = 0
        if local_i < stride:
            temp_val = cache[local_i + stride]
        barrier()

        # write phase, all threads write their computed values
        if local_i < stride:
            cache[local_i] += temp_val
        
        barrier()
        stride //= 2
    
    if local_i == 0:
        output[row, 0] = cache[0]


# ANCHOR_END: axis_sum


def main():
    with DeviceContext() as ctx:
        out = ctx.enqueue_create_buffer[dtype](NROWS).enqueue_fill(0)
        inp = ctx.enqueue_create_buffer[dtype](NROWS * SIZE).enqueue_fill(0)
        with inp.map_to_host() as inp_host:
            for row in range(NROWS):
                for col in range(SIZE):
                    inp_host[row * SIZE + col] = row * SIZE + col

        out_tensor = LayoutTensor[mut=False, dtype, out_layout](
            out.unsafe_ptr()
        )
        inp_tensor = LayoutTensor[mut=False, dtype, in_layout](inp.unsafe_ptr())

        ctx.enqueue_function[axis_sum[in_layout, out_layout]](
            out_tensor,
            inp_tensor,
            SIZE,
            grid_dim=BLOCKS_PER_GRID,
            block_dim=THREADS_PER_BLOCK,
        )

        expected = ctx.enqueue_create_host_buffer[dtype](NROWS).enqueue_fill(0)
        with inp.map_to_host() as inp_host:
            for row in range(NROWS):
                for col in range(SIZE):
                    expected[row] += inp_host[row * SIZE + col]

        ctx.synchronize()

        with out.map_to_host() as out_host:
            print("out:", out)
            print("expected:", expected)
            for i in range(NROWS):
                assert_equal(out_host[i], expected[i])
