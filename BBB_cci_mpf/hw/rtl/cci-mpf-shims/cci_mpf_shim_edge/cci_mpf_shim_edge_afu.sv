//
// Copyright (c) 2016, Intel Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// Neither the name of the Intel Corporation nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

`include "cci_mpf_if.vh"
`include "cci_mpf_shim_edge.vh"
`include "cci_mpf_shim_pwrite.vh"

//
// This is a mandatory connection at the head of an MPF pipeline.
// It canonicalizes input and output and manages the flow of data through
// MPF.
//

module cci_mpf_shim_edge_afu
  #(
    parameter N_WRITE_HEAP_ENTRIES = 0,

    // Is virtual to physical translation enabled?
    parameter ENABLE_VTP = 0,

    // Enforce write/write and write/read ordering with cache lines?
    parameter ENFORCE_WR_ORDER = 0,

    // Enable partial write emulation?
    parameter ENABLE_PARTIAL_WRITES = 0,
    parameter string PARTIAL_WRITE_MODE = "BYTE_MASK",

    // Buffer the AFU to FIU request flow?
    parameter BUFFER_REQUESTS = 0,

    // Register the FIU to AFU response flow?
    parameter REGISTER_RESPONSES = 0
    )
   (
    input  logic clk,

    // Connection toward the FIU (the end of the MPF pipeline nearest the AFU)
    cci_mpf_if.to_fiu fiu,

    // External connections to the AFU
    cci_mpf_if.to_afu afu,

    // Interface to the MPF FIU edge module
    cci_mpf_shim_edge_if.edge_afu fiu_edge,

    // Interface to the partial write emulator
    cci_mpf_shim_pwrite_if.pwrite_edge_afu pwrite
    );

    logic reset;
    assign reset = fiu.reset;

    //
    // Register responses from the host?
    //
    cci_mpf_if fiu_buf (.clk);

    generate
        if (REGISTER_RESPONSES)
        begin : rsp_b
            cci_mpf_shim_buffer_fiu
             bf
               (
                .clk,
                .fiu_raw(fiu),
                .fiu_buf
                );
        end
        else
        begin : no_rsp_b
            // No need for another buffer
            cci_mpf_shim_null
              nbf
               (
                .clk,
                .fiu,
                .afu(fiu_buf)
                );
        end
    endgenerate


    //
    // Canonicalize AFU requests and forward write data to the FIU edge.
    //
    cci_mpf_if afu_wr (.clk);

    cci_mpf_shim_edge_afu_wr_data
      #(
        .N_WRITE_HEAP_ENTRIES(N_WRITE_HEAP_ENTRIES),
        .ENABLE_VTP(ENABLE_VTP),
        .ENFORCE_WR_ORDER(ENFORCE_WR_ORDER),
        .ENABLE_PARTIAL_WRITES(ENABLE_PARTIAL_WRITES),
        .PARTIAL_WRITE_MODE(PARTIAL_WRITE_MODE)
        )
      afu_edge
       (
        .clk,
        .fiu(afu_wr),
        .afu,
        .fiu_edge,
        .pwrite(pwrite)
        );

    //
    // Buffer requests from the AFU and add flow control?  This is typically
    // necessary only when no other module in MPF is providing flow control.
    //
    generate
        if (BUFFER_REQUESTS)
        begin : req_b
            cci_mpf_if afu_buf (.clk);

            // We can afford to delay the almost full signals one cycle
            // to simplify potential combinational logic.
            logic c0TxAlmFull_q;
            logic c1TxAlmFull_q;

            always_ff @(posedge clk)
            begin
                c0TxAlmFull_q <= fiu_buf.c0TxAlmFull;
                c1TxAlmFull_q <= fiu_buf.c1TxAlmFull;
            end

            // Insert a buffer and flow control
            cci_mpf_shim_buffer_afu
              #(
                .THRESHOLD(CCI_TX_ALMOST_FULL_THRESHOLD + 4),
                .REGISTER_OUTPUT(1)
                )
              ba
               (
                .clk,
                .afu_buf,
                .afu_raw(afu_wr),
                // Forward requests whenever transmission is allowed
                .deqC0Tx(cci_mpf_c0TxIsValid(afu_buf.c0Tx) && ! c0TxAlmFull_q),
                .deqC1Tx(cci_mpf_c1TxIsValid(afu_buf.c1Tx) && ! c1TxAlmFull_q)
                );

            // Connect afu_buf and fiu_buf.  The connection is trivial
            // except for turning off the valid bits on requests when flow
            // control prevents requests from being forwarded.
            assign afu_buf.reset = fiu_buf.reset;

            always_comb
            begin
                fiu_buf.c0Tx = cci_mpf_c0TxMaskValids(afu_buf.c0Tx, ! c0TxAlmFull_q);
                fiu_buf.c1Tx = cci_mpf_c1TxMaskValids(afu_buf.c1Tx, ! c1TxAlmFull_q);
                fiu_buf.c2Tx = afu_buf.c2Tx;

                afu_buf.c0TxAlmFull = c0TxAlmFull_q;
                afu_buf.c1TxAlmFull = c1TxAlmFull_q;

                afu_buf.c0Rx = fiu_buf.c0Rx;
                afu_buf.c1Rx = fiu_buf.c1Rx;
            end
        end
        else
        begin : no_req_b
            // No need for flow control here
            cci_mpf_shim_null
              nba
               (
                .clk,
                .fiu(fiu_buf),
                .afu(afu_wr)
                );
        end
    endgenerate

endmodule // cci_mpf_shim_edge_afu


//
// MPF AFU edge transformations.  The most significant transformation breaks
// write data from write requests so the data flows around MPF.
//
module cci_mpf_shim_edge_afu_wr_data
  #(
    parameter N_WRITE_HEAP_ENTRIES = 0,
    parameter ENABLE_VTP = 0,

    // Enforce write/write and write/read ordering with cache lines?
    parameter ENFORCE_WR_ORDER = 0,

    // Enable partial write emulation?
    parameter ENABLE_PARTIAL_WRITES = 0,
    parameter string PARTIAL_WRITE_MODE = "BYTE_MASK"
    )
   (
    input  logic clk,

    // Connection toward the FIU (the end of the MPF pipeline nearest the AFU)
    cci_mpf_if.to_fiu fiu,

    // External connections to the AFU
    cci_mpf_if.to_afu afu,

    // Interface to the MPF FIU edge module
    cci_mpf_shim_edge_if.edge_afu fiu_edge,

    // Interface to the partial write emulator
    cci_mpf_shim_pwrite_if.pwrite_edge_afu pwrite
    );

    logic reset;
    assign reset = fiu.reset;

    // Have the AFU come out of reset a cycle late both to allow the MPF
    // distributed reset tree to complete and to put the AFU in a separate
    // reset domain.
    initial
    begin
        afu.reset = 1'b1;
    end

    always @(posedge clk)
    begin
        afu.reset <= fiu.reset;
    end


    //
    // Save write data as it arrives from the AFU in a heap here.  Use
    // the saved values as requests exit MPF toward the FIU.  This has
    // multiple advantages:
    //
    //   - Internal buffer space inside MPF pipelines is greatly reduced
    //     since the wide request channel 1 data bus is eliminated.
    //
    //   - Multi-beat write requests are easier to handle.  The code
    //     here will send only one write request through MPF.  The remaining
    //     beats are saved in the heap here and regenerated when the
    //     control packet exits MPF.
    //
    typedef logic [$clog2(N_WRITE_HEAP_ENTRIES)-1 : 0] t_write_heap_idx;

    logic wr_heap_alloc;
    logic wr_heap_not_full;
    t_write_heap_idx wr_heap_enq_idx, wr_heap_enq_idx_q;
    t_cci_clNum wr_heap_enq_clNum, wr_heap_enq_clNum_q;

    cci_mpf_prim_heap_ctrl
      #(
        .N_ENTRIES(N_WRITE_HEAP_ENTRIES),
        // Leave space both for the almost full threshold and a full
        // multi-line packet.  To avoid deadlocks we never signal a
        // transition to almost full in the middle of a packet so must
        // be prepared to absorb all flits.
        .MIN_FREE_SLOTS(CCI_TX_ALMOST_FULL_THRESHOLD +
                        CCI_MAX_MULTI_LINE_BEATS + 1)
        )
      wr_heap_ctrl
       (
        .clk,
        .reset,

        // Add entries to the heap as writes arrive from the AFU
        .enq(wr_heap_alloc),
        .notFull(wr_heap_not_full),
        .allocIdx(wr_heap_enq_idx),

        // Free entries as writes leave toward the FIU.
        .free(fiu_edge.free),
        .freeIdx(fiu_edge.freeidx)
        );

    always_ff @(posedge clk)
    begin
        wr_heap_enq_idx_q <= wr_heap_enq_idx;
        wr_heap_enq_clNum_q <= wr_heap_enq_clNum;
    end


    //
    // The heap holding write data is in the FIU edge module.
    //
    always_comb
    begin
        fiu_edge.wen = cci_mpf_c1TxIsWriteReq(afu.c1Tx);
        fiu_edge.widx = wr_heap_enq_idx;
        fiu_edge.wclnum = wr_heap_enq_clNum;
        fiu_edge.wdata = afu.c1Tx.data;

        if (! fiu_edge.wen)
        begin
            fiu_edge.wsop = 1'b0;
            fiu_edge.weop = 1'b0;
        end
        else
        begin
            fiu_edge.wsop = afu.c1Tx.hdr.base.sop;
            // Compute EOP
            if (afu.c1Tx.hdr.base.sop)
            begin
                // Single beat packet?
                fiu_edge.weop = (afu.c1Tx.hdr.base.cl_len == eCL_LEN_1);
            end
            else
            begin
                // End of multi-beat packet?
                fiu_edge.weop = (wr_heap_enq_clNum == c1tx_sop_hdr.base.cl_len);
            end
        end
    end


    // ====================================================================
    //
    // Forward partial write requests to the partial write emulator.
    //
    // ====================================================================

    t_if_cci_mpf_c1_Tx afu_c1Tx_q;
    always_ff @(posedge clk)
    begin
        afu_c1Tx_q <= afu.c1Tx;
        if (reset)
        begin
            afu_c1Tx_q.valid <= 1'b0;
        end
    end

    //
    // The partial write emulator uses a mask to select bytes within a line.
    // Construct the mask here when in CCI-P byte range mode.
    //

    //
    // Generate a mask selecting all bytes in a line above and including start_idx.
    //
    t_cci_mpf_clDataByteMask pwmask_from_range;

    cci_mpf_shim_edge_afu_pwmask
     gen_pwmask
       (
        .clk,
        .reset,
        .c1Tx(afu.c1Tx),
        .pwmask(pwmask_from_range)
        );

    always_ff @(posedge clk)
    begin
        pwrite.wen <= cci_mpf_c1TxIsWriteReq(afu_c1Tx_q);
        pwrite.widx <= wr_heap_enq_idx_q;
        pwrite.wclnum <= wr_heap_enq_clNum_q;

        if (ENABLE_PARTIAL_WRITES && ((PARTIAL_WRITE_MODE) != "BYTE_MASK"))
        begin
            // Partial write was specified as a byte range using CCI-P native
            // encoding. Save the corresponding bit mask generated here.
            pwrite.wpartial.isPartialWrite <= 1'b0;
            pwrite.wpartial.mask <= pwmask_from_range;
        end
        else
        begin
            pwrite.wpartial <= afu_c1Tx_q.hdr.pwrite;
            if (! afu_c1Tx_q.hdr.pwrite.isPartialWrite)
            begin
                // Turn off the mask if this isn't a partial write. Multi-beat
                // requests may have isPartialWrite set on any beat, so this
                // mask ultimately may be used even when isPartialWrite is
                // false for the current beat.
                pwrite.wpartial.mask <= ~ (t_cci_mpf_clDataByteMask'(0));
            end
        end

        if (reset)
        begin
            pwrite.wen <= 1'b0;
        end
    end

    // ====================================================================
    //
    //   AFU edge flow
    //
    // ====================================================================

    logic afu_wr_packet_active;
    logic afu_wr_eop;

    assign wr_heap_alloc = cci_mpf_c1TxIsWriteReq(afu.c1Tx) && afu_wr_eop;

    // All but write requests flow straight through. The c1Tx channel needs
    // to be registered in this module due to the logic that drops all but
    // one flit from a multi-beat write.  If read/write order is being
    // enforced than add the same register latency for c0Tx.
    generate
        if (ENFORCE_WR_ORDER)
        begin : wr_order
            always_ff @(posedge clk)
            begin
                fiu.c0Tx <= cci_mpf_updC0TxCanonical(afu.c0Tx);
            end
        end
        else
        begin : no_wr_order
            assign fiu.c0Tx = cci_mpf_updC0TxCanonical(afu.c0Tx);
        end
    endgenerate

    assign fiu.c2Tx = afu.c2Tx;

    //
    // Register almost full signals before they reach the AFU.  MPF modules
    // must accommodate the extra cycle of buffering that may be needed
    // as a result of signalling almost full a cycle late.
    //
    always_ff @(posedge clk)
    begin
        afu.c0TxAlmFull <= fiu.c0TxAlmFull;

        afu.c1TxAlmFull <= fiu.c1TxAlmFull ||
                           ! wr_heap_not_full ||
                           fiu_edge.wAlmFull;

        if (reset)
        begin
            afu.c0TxAlmFull <= 1'b1;
            afu.c1TxAlmFull <= 1'b1;
        end
    end

    assign afu.c0Rx = fiu.c0Rx;
    assign afu.c1Rx = fiu.c1Rx;

    //
    // The CCI spec. allows both address and cl_len of non-sop flits in a
    // multi-beat packet to be don't care, which is rather annoying.
    // Register the sop values and add a mux to recover them.
    //
    t_cci_mpf_c1_ReqMemHdr c1tx_sop_hdr;

    always_ff @(posedge clk)
    begin
        if (cci_mpf_c1TxIsValid(afu.c1Tx) && afu.c1Tx.hdr.base.sop)
        begin
            c1tx_sop_hdr <=
                cci_mpf_updC1TxCanonicalHdr(afu.c1Tx.hdr,
                                            cci_mpf_c1TxIsWriteReq(afu.c1Tx));
        end
        else if (cci_mpf_c1TxIsWriteReq(afu.c1Tx) &&
                 afu.c1Tx.hdr.pwrite.isPartialWrite)
        begin
            // Setting isPartialWrite in any beat of a multi-line write
            // makes the write partial.
            c1tx_sop_hdr.pwrite.isPartialWrite <= 1'b1;
        end
    end

    // Generate canonical c1Tx, including cl_len and address.
    t_if_cci_mpf_c1_Tx afu_canon_c1Tx;

    always_comb
    begin
        afu_canon_c1Tx = cci_mpf_updC1TxCanonical(afu.c1Tx);

        // Some header fields in multi-line writes must be preserved from
        // the start packet.
        if (! afu.c1Tx.hdr.base.sop &&
            cci_mpf_c1TxIsWriteReq_noCheckValid(afu.c1Tx))
        begin
            afu_canon_c1Tx.hdr.base.cl_len = c1tx_sop_hdr.base.cl_len;
            afu_canon_c1Tx.hdr.base.address = c1tx_sop_hdr.base.address;
            afu_canon_c1Tx.hdr.ext = c1tx_sop_hdr.ext;
            afu_canon_c1Tx.hdr.pwrite.isPartialWrite =
                afu_canon_c1Tx.hdr.pwrite.isPartialWrite ||
                c1tx_sop_hdr.pwrite.isPartialWrite;
        end

        if ((ENABLE_PARTIAL_WRITES == 0) || ((PARTIAL_WRITE_MODE) != "BYTE_MASK"))
        begin
            afu_canon_c1Tx.hdr.pwrite.isPartialWrite = 1'b0;
            afu_canon_c1Tx.hdr.pwrite.mask = t_cci_mpf_clDataByteMask'(0);
        end
    end


    always_ff @(posedge clk)
    begin
        fiu.c1Tx <= afu_canon_c1Tx;

        // The cache line's value stored in fiu.c1Tx.data is no longer needed
        // in the pipeline.  Store 'x but use the low bits to hold the
        // local heap index.
        fiu.c1Tx.data <= 'x;
        fiu.c1Tx.data[$clog2(N_WRITE_HEAP_ENTRIES) - 1 : 0] <= wr_heap_enq_idx;

        // The partial write mask was forwarded to the FIU edge module along
        // with the write data.
        fiu.c1Tx.hdr.pwrite.mask <= 'x;

        // Multi-beat write request?  Only the start of packet beat goes
        // through MPF.  The rest are buffered in wr_heap here and the
        // packets will be regenerated when the sop packet exits.
        //
        // Only pass requests that are either the end of a write or
        // that aren't writes.
        if (cci_mpf_c1TxIsWriteReq_noCheckValid(afu_canon_c1Tx))
        begin
            // Wait for the final flit to arrive and be buffered, thus
            // guaranteeing that all the data is ready to be written
            // as the packet exits to the FIU.
            fiu.c1Tx.valid <= afu_canon_c1Tx.valid &&
                              (wr_heap_enq_clNum == afu_canon_c1Tx.hdr.base.cl_len);

            fiu.c1Tx.hdr.base.sop <= 1'b1;
        end
    end


    //
    // Validate request.  All the remaining code is just validation that
    // multi-beat requests are formatted properly.
    //

    cci_mpf_prim_track_multi_write
      afu_wr_track
       (
        .clk,
        .reset,
        .c1Tx(afu_canon_c1Tx),
        .c1Tx_en(1'b1),
        .eop(afu_wr_eop),
        .packetActive(afu_wr_packet_active),
        .nextBeatNum(wr_heap_enq_clNum)
        );

    //synthesis translate_off
    t_cci_clLen afu_wr_prev_cl_len;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            // Nothing
        end
        else
        begin
            if (cci_mpf_c0TxIsReadReq(afu.c0Tx))
            begin
                assert((afu.c0Tx.hdr.base.address[1:0] & afu.c0Tx.hdr.base.cl_len) == 2'b0) else
                    $fatal(2, "cci_mpf_shim_edge_connect: Multi-beat read address must be naturally aligned, cl_len=%0d, addr=0x%x",
                           afu.c0Tx.hdr.base.cl_len, afu.c0Tx.hdr.base.address);
            end

`ifdef CCIP_ENCODING_HAS_RDLSPEC
            // When a speculative read request arrives confirm that something can consume it.
            // Either VTP must be enabled or the platform must support speculative reads.
            if (cci_mpf_c0TxIsSpecReadReq(afu.c0Tx))
            begin
                assert(ENABLE_VTP || (ccip_cfg_pkg::C0_REQ_RDLSPEC_S & ccip_cfg_pkg::C0_SUPPORTED_REQS)) else
                    $fatal(2, "cci_mpf_shim_edge_connect: Platform does not support speculative reads and VTP not enabled!");
            end
`endif

            if (cci_mpf_c1TxIsWriteReq(afu_canon_c1Tx))
            begin
                assert(afu.c1Tx.hdr.base.sop != afu_wr_packet_active) else
                    if (! afu.c1Tx.hdr.base.sop)
                        $fatal(2, "cci_mpf_shim_edge_connect: Expected SOP flag on write");
                    else
                        $fatal(2, "cci_mpf_shim_edge_connect: Wrong number of multi-beat writes");

                if (afu.c1Tx.hdr.base.sop)
                begin
                    assert ((afu.c1Tx.hdr.base.address[1:0] & afu_canon_c1Tx.hdr.base.cl_len) == 2'b0) else
                        $fatal(2, "cci_mpf_shim_edge_connect: Multi-beat write address must be naturally aligned");
`ifdef CCIP_ENCODING_HAS_BYTE_WR
                    assert ((afu.c1Tx.hdr.base.mode == eMOD_CL) || (afu.c1Tx.hdr.base.cl_len == eCL_LEN_1)) else
                        $fatal(2, "cci_mpf_shim_edge_connect: Byte range not allowed on multi-beat write");
                    assert ((afu.c1Tx.hdr.base.mode == eMOD_BYTE) ||
                            ((afu.c1Tx.hdr.base.byte_start == 0) && (afu.c1Tx.hdr.base.byte_len == 0))) else
                        $fatal(2, "cci_mpf_shim_edge_connect: byte_start and byte_len must be 0 when write mode isn't eMOD_BYTE");
`endif
                end
                else
                begin
                    assert (afu_wr_prev_cl_len == afu_canon_c1Tx.hdr.base.cl_len) else
                        $fatal(2, "cci_mpf_shim_edge_connect: cl_len must be the same in all beats of a multi-line write");
                end

                afu_wr_prev_cl_len <= afu_canon_c1Tx.hdr.base.cl_len;
            end
        end
    end
    //synthesis translate_on

endmodule // cci_mpf_shim_edge_afu_wr_data


//
// Generate a partial write mask from a byte range.
//
module cci_mpf_shim_edge_afu_pwmask
   (
    input  logic clk,
    input  logic reset,
    input  t_if_cci_mpf_c1_Tx c1Tx,

    // pwmask_from_range is generated one cycle after the input c1Tx
    output t_cci_mpf_clDataByteMask pwmask
    );

`ifdef CCIP_ENCODING_HAS_BYTE_WR

    function automatic t_cci_mpf_clDataByteMask decodeMaskStart(t_ccip_clByteIdx start_idx);
        t_cci_mpf_clDataByteMask masks[CCIP_CLDATA_BYTE_WIDTH];

        // Build a lookup table, with 1's in all bits idx and higher.
        masks[0] = ~t_cci_mpf_clDataByteMask'(0);
        for (int i = 1; i < CCIP_CLDATA_BYTE_WIDTH; i = i + 1)
        begin
            // Shift in another 0
            masks[i] = masks[i-1] << 1;
        end

        return masks[start_idx];
    endfunction

    //
    // Generate a mask selecting all bytes in a line below end_idx. The range does not
    // include end_idx, which avoids having to subtract 1 when computing end_idx
    // from the sum of the start index and length.
    //
    function automatic t_cci_mpf_clDataByteMask decodeMaskEnd(t_ccip_clByteIdx end_idx);
        t_cci_mpf_clDataByteMask masks[CCIP_CLDATA_BYTE_WIDTH];

        // Build a lookup table, with 0's in all bits above idx. The table is rotated
        // by 1 since the mask does not include the bit at end_idx.
        masks[1] = 1;
        for (int i = 2; i < CCIP_CLDATA_BYTE_WIDTH; i = i + 1)
        begin
            // Shift in another 1
            masks[i] = (masks[i-1] << 1) | 1'b1;
        end
        masks[0] = ~t_cci_mpf_clDataByteMask'(0);

        return masks[end_idx];
    endfunction

    //
    // Generate the mask unconditionally. Whether or not the write is actually a partial
    // line is computed elsewhere.
    //
    t_ccip_clByteIdx start_idx;
    t_ccip_clByteIdx end_idx;

    always_ff @(posedge clk)
    begin
        start_idx <= cci_mpf_c1TxByteRangeStart(c1Tx);

        // decodeMaskEnd() is coded to avoid having to subtract 1 when computing end_idx
        end_idx <= cci_mpf_c1TxByteRangeStart(c1Tx) + cci_mpf_c1TxByteRangeLen(c1Tx);
    end

    assign pwmask = decodeMaskStart(start_idx) & decodeMaskEnd(end_idx);

`else

    // No native CCI-P encoding defined.
    assign pwmask = t_cci_mpf_clDataByteMask'(0);

`endif

endmodule // cci_mpf_shim_edge_afu_pwmask
