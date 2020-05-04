// Copyright (c) 2020 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Author: Wolfgang Roenninger <wroennin@ethz.ch>

`include "axi/typedef.svh"
`include "common_cells/registers.svh"
/// AXI4-Lite Registers with option to make individual registers read-only.
/// This module exposes a number of registers on an AXI4-Lite bus modeled with structs.
/// It responds to accesses outside the instantiated registers with a slave error.
/// Some of the registers can be configured to be read-only.
module axi_lite_regs #(
  /// DEPENDENT PARAMETER, DO NOT OVERWRITE! Type of a byte is 8 bits (constant).
  parameter type byte_t = logic [7:0],
  /// The size of the register field in bytes mapped on the AXI4-Lite port.
  ///
  /// The field starts at a `0x0` aligned address on the AXI and is continuous up to
  /// address `0xNumbytes-1`. The module will only consider the LSBs of the address which fall into
  /// the range `axi_req_i.ax.addr[$clog2(RegNumBytes)-1:0`. The other address bits are ignored.
  ///
  /// The register indices `byte_index` of the register array are used to describe the functionality
  /// of the other parameters and ports in regards to an individual byte mapped at `byte_index`.
  /// A `chunk` is used to define the grouping of multiple registers onto the byte lanes of the
  /// AXI4-Lite data channels.
  ///
  /// The register bytes are mapped to the data lanes of the AXI channel as follows:
  /// Eg: `RegNumBytes == 32'd11`, `AxiDataWidth == 32'd32`
  ///
  /// AXI strb:                           3 2 1 0 (AXI)
  ///                                     | | | |
  ///                           *---------* | | |
  ///                   *-------|-*-------|-* | |
  ///                   | *-----|-|-*-----|-|-* |
  ///                   | | *---|-|-|-*---|-|-|-*
  ///                   | | |   | | | |   | | | |
  /// `byte_index`:     A 9 8   7 6 5 4   3 2 1 0 (reg)
  ///               | chunk_2 | chunk_1 | chunk_0 |
  ///
  /// If one wants to have holes in the address map/reserved bits the parameters/signals on the
  /// ports `AxiReadOnly`, `ref_d_i`, `reg_q_o`, have to be defined accordingly.
  parameter int unsigned             RegNumBytes  = 32'd0,
  /// Address width of `axi_req_i.aw.addr` and `axi_req_i.ar.addr`. Is used to generate internal
  /// address map of the AXI4-Lite data lanes onto register bytes.
  parameter int unsigned             AxiAddrWidth = 32'd0,
  /// Data width of the AXI4-Lite bus. Register address map is generated with this value.
  /// The mapping of the register bytes into chunks depends on this value.
  parameter int unsigned             AxiDataWidth = 32'd0,
  /// Privileged accesses only. The slave only executes AXI4-Lite transactions if the `AxProt[0]`
  /// bit in the `AW` or `AR` vector is set, otherwise ignores writes and answers with
  /// `axi_pkg::RESP_SLVERR` to transactions.
  parameter bit                      PrivProtOnly = 1'b0,
  /// Secure accesses only. The slave only executes AXI4-Lite transactions if the `AxProt[1]` bit
  /// in the `AW` or `AR` vector is set, otherwise ignores writes and answers with
  /// `axi_pkg::RESP_SLVERR` to transactions.
  parameter bit                      SecuProtOnly = 1'b0,
  /// This flag can specify a AXI4 read-only register at given `byte_index` of the register array.
  ///
  /// This flag only applies for AXI4-Lite write transactions. The register byte can be loaded
  /// directly by asserting `reg_load_i[byte_index]`. When `AxiReadOnly[reg_index] is set to 1'b1`,
  /// the corresponding `axi_req_i.w.strb` signal is prevented to assert at the load signal of the
  /// corresponding register byte address.
  ///
  /// The B response will be `axi_pkg::RESP_OKAY` as long as at least one byte has been written,
  /// even when partial byte write have been prevented by this flag! This is to allow the usage
  /// of the full AXI bus width to write on read-only segmented fields.
  /// When no byte has been written the module will answer with `axi_pkg::RESP_SLVERR`.
  ///
  /// If one wants to constant propagate a byte in the register array:
  /// - Set `AxiReadOnly[byte_index]` to 1'b1.
  /// - Set `reg_load_i[byte_index] constant to 1'b0.
  /// Then the byte at `reg_q_o[byte_index]` will be equal to `RegRstVal[byte_index]` and constant.
  parameter logic  [RegNumBytes-1:0] AxiReadOnly  = {RegNumBytes{1'b0}},
  /// Reset value for the whole register array.
  /// Is an array of bytes with range `[RegNumBytes-1:0]`.
  parameter byte_t [RegNumBytes-1:0] RegRstVal    = {RegNumBytes{8'h00}},
  /// AXI4-Lite request struct. See macro definition in `include/typedef.svh`.
  /// Is required to be specified.
  parameter type                     req_lite_t   = logic,
  /// AXI4-Lite response struct. See macro definition in `include/typedef.svh`.
  /// Is required to be specified.
  parameter type                     resp_lite_t  = logic
) (
  /// Clock input signal (1-bit).
  input  logic                    clk_i,
  /// Asynchronous active low reset signal (1-bit).
  input  logic                    rst_ni,
  /// AXI4-Lite slave port request struct, bundles all AXI4-Lite signals from the master.
  /// This module will perform the write transaction when `axi_req_i.aw_valid` and
  /// `axi_req_i.w_valid` are both asserted.
  input  req_lite_t               axi_req_i,
  /// AXI4-Lite slave port response struct, bundles all AXI4-Lite signals to the master.
  output resp_lite_t              axi_resp_o,
  /// Flag to tell logic that the AXI is writing these bytes this cycle. The new data
  /// where `wr_active[byte_index] && AxiReadOnly[byte_index] == 1'b0` is available in the
  /// next cycle at `reg_q_o[byte_index]`. This signal is directly generated from the signal
  /// axi_req_i.w.strb and is asserted regardless of the value of `AxiReadOnly`.
  ///
  /// Is only active when the AXI prot flag from the channel has the right access permission.
  output logic  [RegNumBytes-1:0] wr_active_o,
  /// Flag to tell logic that the AXI is reading the value of the bytes at `reg_q_o[byte_index]`
  /// this cycle.
  ///
  /// Is only active when the AXI prot flag from the channel has the right access permission.
  output logic  [RegNumBytes-1:0] rd_active_o,
  /// Load value for each register. Can be used to directly load a new value into the registers
  /// from logic.
  ///
  /// If not used set to `'0`.
  input  byte_t [RegNumBytes-1:0] reg_d_i,
  /// Load enable for each register.
  /// Each byte can be loaded directly by asserting `reg_load_i[byte_index]` to `1'b1`.
  /// The load value from `reg_d_i[byte_index]` is then available in the next cycle at
  /// `reg_q_o[byte_index]`.
  ///
  /// If the load signal is active, an AXI4-Lite write transactions is stalled, when it writes onto
  /// the same register chunk where at least one `reg_load_i[byte_index]` is asserted! It is
  /// stalled until all `reg_load_i` mapped onto the same chunk are `'0`!
  ///
  /// If not used set to `'0`;
  input  logic  [RegNumBytes-1:0] reg_load_i,
  /// Register state output.
  output byte_t [RegNumBytes-1:0] reg_q_o
);
  // Define the number of register chunks needed to map all `RegNumBytes` to the AXI channel.
  // Eg: `AxiDataWidth == 32'd32`
  // AXI strb:                       3 2 1 0
  //                                 | | | |
  //             *---------*---------* | | |
  //             | *-------|-*-------|-* | |
  //             | | *-----|-|-*-----|-|-* |
  //             | | | *---|-|-|-*---|-|-|-*
  //             | | | |   | | | |   | | | |
  // Reg byte:   B A 9 8   7 6 5 4   3 2 1 0
  //           | chunk_2 | chunk_1 | chunk_0 |
  localparam int unsigned AxiStrbWidth  = AxiDataWidth / 32'd8;
  localparam int unsigned NumChunks     = cf_math_pkg::ceil_div(RegNumBytes, AxiStrbWidth);
  localparam int unsigned ChunkIdxWidth = (NumChunks > 32'd1) ? $clog2(NumChunks) : 32'd1;
  // Type of the index to identify a specific register chunk.
  typedef logic [ChunkIdxWidth-1:0] chunk_idx_t;

  // Find out how many bits of the address are applicable for this module.
  // Look at the `AddrWidth` number of LSBs to calculate the multiplexer index of the AXI.
  localparam int unsigned AddrWidth = (RegNumBytes > 32'd1) ? $clog2(RegNumBytes) : 32'd1;
  typedef logic [AddrWidth-1:0] addr_t;

  // Define the address map which maps each register chunk onto an AXI address.
  typedef struct packed {
    int unsigned idx;
    addr_t       start_addr;
    addr_t       end_addr;
  } axi_rule_t;
  axi_rule_t    [NumChunks-1:0] addr_map;
  for (genvar i = 0; i < NumChunks; i++) begin : gen_addr_map
    assign addr_map[i] = axi_rule_t'{
      idx:        i,
      start_addr: addr_t'( i   * AxiStrbWidth),
      end_addr:   addr_t'((i+1)* AxiStrbWidth)
    };
  end

  // Channel definitions for spill register
  typedef logic [AxiDataWidth-1:0] axi_data_t;
  `AXI_LITE_TYPEDEF_B_CHAN_T(b_chan_lite_t)
  `AXI_LITE_TYPEDEF_R_CHAN_T(r_chan_lite_t, axi_data_t)

  // Register array declarations
  byte_t [RegNumBytes-1:0] reg_q,        reg_d;
  logic  [RegNumBytes-1:0] reg_update;

  // Write logic
  chunk_idx_t              aw_chunk_idx;
  logic                    aw_dec_valid;
  b_chan_lite_t            b_chan;
  logic                    b_valid,      b_ready;
  logic                    aw_prot_ok;
  logic  [NumChunks-1:0]   chunk_loaded, chunk_ro;

  // Flag for telling that the protection level is the right one.
  assign aw_prot_ok = (PrivProtOnly ? axi_req_i.aw.prot[0] : 1'b1) &
                      (SecuProtOnly ? axi_req_i.aw.prot[1] : 1'b1);
  // Have a flag which is true if any of the bytes inside a chunk are directly loaded.
  for (genvar i = 0; i < NumChunks; i++) begin : gen_chunk_load
    logic [AxiStrbWidth-1:0] load;
    logic [AxiStrbWidth-1:0] read_only;
    for (genvar j = 0; j < AxiStrbWidth; j++) begin : gen_load_assign
      localparam int unsigned RegByteIdx = i*AxiStrbWidth + j;
      assign load[j]      = (RegByteIdx < RegNumBytes) ? reg_load_i[RegByteIdx]  : 1'b0;
      assign read_only[j] = (RegByteIdx < RegNumBytes) ? AxiReadOnly[RegByteIdx] : 1'b1;
    end
    assign chunk_loaded[i] = |load;
    assign chunk_ro[i]     = &read_only;
  end

  // Register write logic.
  always_comb begin
    automatic int unsigned reg_byte_idx = '0;
    // default assignments
    reg_d               = reg_q;
    reg_update          = '0;
    // Channel handshake
    axi_resp_o.aw_ready = 1'b0;
    axi_resp_o.w_ready  = 1'b0;
    // Response
    b_chan              = b_chan_lite_t'{resp: axi_pkg::RESP_SLVERR, default: '0};
    b_valid             = 1'b0;
    // write active flag
    wr_active_o         = '0;

    // Control
    // Handle all non AXI register loads.
    for (int unsigned i = 0; i < RegNumBytes; i++) begin
      if (reg_load_i[i]) begin
        reg_d[i]      = reg_d_i[i];
        reg_update[i] = 1'b1;
      end
    end

    // Handle load from AXI write.
    // `b_ready` is allowed to be a condition as it comes from a spill register.
    if (axi_req_i.aw_valid && axi_req_i.w_valid && b_ready) begin
      // The write can be performed when these conditions are true:
      // - AW decode is valid.
      // - `axi_req_i.aw.prot` has the right value.
      if (aw_dec_valid && aw_prot_ok) begin
        // Stall write as long as any direct load is going on in the current chunk.
        if (!chunk_loaded[aw_chunk_idx]) begin
          // Go through all bytes on the W channel.
          for (int unsigned i = 0; i < AxiStrbWidth; i++) begin
            reg_byte_idx = unsigned'(aw_chunk_idx) * AxiStrbWidth + i;
            // Only execute if the byte is mapped onto the register array.
            if (reg_byte_idx < RegNumBytes) begin
              reg_d[reg_byte_idx]       = axi_req_i.w.data[8*i+:8];
              // Only update the reg From an AXI write if it is not `ReadOnly`.
              reg_update[reg_byte_idx]  = axi_req_i.w.strb[i] & !AxiReadOnly[reg_byte_idx];
              wr_active_o[reg_byte_idx] = axi_req_i.w.strb[i];
            end
          end
          b_chan.resp         = chunk_ro[aw_chunk_idx] ? axi_pkg::RESP_SLVERR : axi_pkg::RESP_OKAY;
          b_valid             = 1'b1;
          axi_resp_o.aw_ready = 1'b1;
          axi_resp_o.w_ready  = 1'b1;
        end
      end else begin
        // Send default B error response on each not allowed write transaction.
        b_valid             = 1'b1;
        axi_resp_o.aw_ready = 1'b1;
        axi_resp_o.w_ready  = 1'b1;
      end
    end
  end

  // Read logic
  chunk_idx_t   ar_chunk_idx;
  logic         ar_dec_valid;
  r_chan_lite_t r_chan;
  logic         r_valid,      r_ready;
  logic         ar_prot_ok;
  assign ar_prot_ok = (PrivProtOnly ? axi_req_i.ar.prot[0] : 1'b1) &
                      (SecuProtOnly ? axi_req_i.ar.prot[1] : 1'b1);
  // Multiplexer to determine R channel
  always_comb begin
    automatic int unsigned reg_byte_idx = '0;
    // Default R channel throws an error.
    r_chan = r_chan_lite_t'{
      data: axi_data_t'(32'hBA5E1E55),
      resp: axi_pkg::RESP_SLVERR,
      default: '0
    };
    // Default nothing is reading the registers
    rd_active_o = '0;
    // Read is valid on a chunk
    if (ar_dec_valid && ar_prot_ok) begin
      // Calculate the corresponding byte index from `ar_chunk_idx`.
      for (int unsigned i = 0; i < AxiStrbWidth; i++) begin
        reg_byte_idx = unsigned'(ar_chunk_idx) * AxiStrbWidth + i;
        // Guard to not index outside the `reg_q_o` array.
        if (reg_byte_idx < RegNumBytes) begin
          r_chan.data[8*i+:8]       = reg_q_o[reg_byte_idx];
          rd_active_o[reg_byte_idx] = r_valid & r_ready;
        end else begin
          r_chan.data[8*i+:8] = 8'h00;
        end
      end
      r_chan.resp = axi_pkg::RESP_OKAY;
    end
  end

  assign r_valid             = axi_req_i.ar_valid; // to spill register
  assign axi_resp_o.ar_ready = r_ready;            // from spill register

  // Register array mapping, even read only register can be loaded over `reg_load_i`.
  for (genvar i = 0; i < RegNumBytes; i++) begin : gen_rw_regs
    `FFLARN(reg_q[i], reg_d[i], reg_update[i], RegRstVal[i], clk_i, rst_ni)
    assign reg_q_o[i] = reg_q[i];
  end

  addr_decode #(
    .NoIndices ( NumChunks  ),
    .NoRules   ( NumChunks  ),
    .addr_t    ( addr_t     ),
    .rule_t    ( axi_rule_t )
  ) i_aw_decode (
    .addr_i           ( addr_t'(axi_req_i.aw.addr) ), // Only look at the `AddrWidth` LSBs.
    .addr_map_i       ( addr_map                   ),
    .idx_o            ( aw_chunk_idx               ),
    .dec_valid_o      ( aw_dec_valid               ),
    .dec_error_o      ( /*not used*/               ),
    .en_default_idx_i ( '0                         ),
    .default_idx_i    ( '0                         )
  );

  addr_decode #(
    .NoIndices ( NumChunks  ),
    .NoRules   ( NumChunks  ),
    .addr_t    ( addr_t     ),
    .rule_t    ( axi_rule_t )
  ) i_ar_decode (
    .addr_i           ( addr_t'(axi_req_i.ar.addr) ), // Only look at the `AddrWidth` LSBs.
    .addr_map_i       ( addr_map                   ),
    .idx_o            ( ar_chunk_idx               ),
    .dec_valid_o      ( ar_dec_valid               ),
    .dec_error_o      ( /*not used*/               ),
    .en_default_idx_i ( '0                         ),
    .default_idx_i    ( '0                         )
  );

  // Add a cycle delay on AXI response, cut all comb paths between slave port inputs and outputs.
  spill_register #(
    .T      ( b_chan_lite_t ),
    .Bypass ( 1'b0          )
  ) i_b_spill_register (
    .clk_i,
    .rst_ni,
    .valid_i ( b_valid            ),
    .ready_o ( b_ready            ),
    .data_i  ( b_chan             ),
    .valid_o ( axi_resp_o.b_valid ),
    .ready_i ( axi_req_i.b_ready  ),
    .data_o  ( axi_resp_o.b       )
  );

  // Add a cycle delay on AXI response, cut all comb paths between slave port inputs and outputs.
  spill_register #(
    .T      ( r_chan_lite_t ),
    .Bypass ( 1'b0          )
  ) i_r_spill_register (
    .clk_i,
    .rst_ni,
    .valid_i ( r_valid            ),
    .ready_o ( r_ready            ),
    .data_i  ( r_chan             ),
    .valid_o ( axi_resp_o.r_valid ),
    .ready_i ( axi_req_i.r_ready  ),
    .data_o  ( axi_resp_o.r       )
  );

  // Validate parameters.
  // pragma translate_off
  `ifndef VERILATOR
    initial begin: p_assertions
      assert (RegNumBytes > 32'd0) else
          $fatal(1, "The number of bytes must be at least 1!");
      assert (AxiAddrWidth >= AddrWidth) else
          $fatal(1, "AxiAddrWidth is not wide enough, has to be at least %0d-bit wide!", AddrWidth);
      assert ($bits(axi_req_i.aw.addr) == AxiAddrWidth) else
          $fatal(1, "AddrWidth does not match req_i.aw.addr!");
      assert ($bits(axi_req_i.ar.addr) == AxiAddrWidth) else
          $fatal(1, "AddrWidth does not match req_i.ar.addr!");
      assert (AxiDataWidth == $bits(axi_req_i.w.data)) else
          $fatal(1, "AxiDataWidth has to be: AxiDataWidth == $bits(axi_req_i.w.data)!");
      assert (AxiDataWidth == $bits(axi_resp_o.r.data)) else
          $fatal(1, "AxiDataWidth has to be: AxiDataWidth == $bits(axi_resp_o.r.data)!");
      assert (RegNumBytes == $bits(AxiReadOnly)) else
          $fatal(1, "Each register needs a `ReadOnly` flag!");
    end
    default disable iff (~rst_ni);
    for (genvar i = 0; i < RegNumBytes; i++) begin
      assert property (@(posedge clk_i) (!reg_load_i[i] && AxiReadOnly[i] |=> $stable(reg_q_o[i])))
          else $fatal(1, "Read-only register at `byte_index: %0d` was changed by AXI!", i);
    end
  `endif
  // pragma translate_on
endmodule

`include "axi/assign.svh"
/// AXI4-Lite Registers with option to make individual registers read-only.
/// This module is an interface wrapper for `axi_lite_regs`. The parameters have the same
/// function as the ones in `axi_lite_regs`, however are defined in `ALL_CAPS`.
module axi_lite_regs_intf #(
  /// DEPENDENT PARAMETER, DO NOT OVERWRITE!
  parameter type byte_t = logic [7:0],
  /// See `axi_lite_reg`: `RegNumBytes`.
  parameter int unsigned               REG_NUM_BYTES  = 32'd0,
  /// See `axi_lite_reg`: `AxiAddrWidth`.
  parameter int unsigned               AXI_ADDR_WIDTH = 32'd0,
  /// See `axi_lite_reg`: `AxiDataWidth`.
  parameter int unsigned               AXI_DATA_WIDTH = 32'd0,
  /// See `axi_lite_reg`: `PrivProtOnly`.
  parameter bit                        PRIV_PROT_ONLY = 1'd0,
  /// See `axi_lite_reg`: `SecuProtOnly`.
  parameter bit                        SECU_PROT_ONLY = 1'd0,
  /// See `axi_lite_reg`: `AxiReadOnly`.
  parameter logic  [REG_NUM_BYTES-1:0] AXI_READ_ONLY  = {REG_NUM_BYTES{1'b0}},
  /// See `axi_lite_reg`: `RegRstVal`
  parameter byte_t [REG_NUM_BYTES-1:0] REG_RST_VAL    = {REG_NUM_BYTES{8'h00}}
) (
  /// Clock input signal (1-bit).
  input  logic                         clk_i,
  /// Asynchronous active low reset signal (1-bit).
  input  logic                         rst_ni,
  /// AXI4-Lite slave port interface.
  AXI_LITE.Slave                       slv,
  /// See `axi_lite_reg`: `wr_active_o`.
  output logic  [REG_NUM_BYTES-1:0] wr_active_o,
  /// See `axi_lite_reg`: `rd_active_o`.
  output logic  [REG_NUM_BYTES-1:0] rd_active_o,
  /// See `axi_lite_reg`: `reg_d_i`.
  input  byte_t [REG_NUM_BYTES-1:0] reg_d_i,
  /// See `axi_lite_reg`: `reg_load_i`.
  input  logic  [REG_NUM_BYTES-1:0] reg_load_i,
  /// See `axi_lite_reg`: `reg_q_o`.
  output byte_t [REG_NUM_BYTES-1:0] reg_q_o
);
  typedef logic [AXI_ADDR_WIDTH-1:0]   addr_t;
  typedef logic [AXI_DATA_WIDTH-1:0]   data_t;
  typedef logic [AXI_DATA_WIDTH/8-1:0] strb_t;
  `AXI_LITE_TYPEDEF_AW_CHAN_T(aw_chan_lite_t, addr_t)
  `AXI_LITE_TYPEDEF_W_CHAN_T(w_chan_lite_t, data_t, strb_t)
  `AXI_LITE_TYPEDEF_B_CHAN_T(b_chan_lite_t)
  `AXI_LITE_TYPEDEF_AR_CHAN_T(ar_chan_lite_t, addr_t)
  `AXI_LITE_TYPEDEF_R_CHAN_T(r_chan_lite_t, data_t)
  `AXI_LITE_TYPEDEF_REQ_T(req_lite_t, aw_chan_lite_t, w_chan_lite_t, ar_chan_lite_t)
  `AXI_LITE_TYPEDEF_RESP_T(resp_lite_t, b_chan_lite_t, r_chan_lite_t)

  req_lite_t  axi_lite_req;
  resp_lite_t axi_lite_resp;

  `AXI_LITE_ASSIGN_TO_REQ(axi_lite_req, slv)
  `AXI_LITE_ASSIGN_FROM_RESP(slv, axi_lite_resp)

  axi_lite_regs #(
    .RegNumBytes  ( REG_NUM_BYTES  ),
    .AxiAddrWidth ( AXI_ADDR_WIDTH ),
    .AxiDataWidth ( AXI_DATA_WIDTH ),
    .PrivProtOnly ( PRIV_PROT_ONLY ),
    .SecuProtOnly ( SECU_PROT_ONLY ),
    .AxiReadOnly  ( AXI_READ_ONLY  ),
    .RegRstVal    ( REG_RST_VAL    ),
    .req_lite_t   ( req_lite_t     ),
    .resp_lite_t  ( resp_lite_t    )
  ) i_axi_lite_regs (
    .clk_i,                         // Clock
    .rst_ni,                        // Asynchronous reset active low
    .axi_req_i   ( axi_lite_req  ), // AXI4-Lite request struct
    .axi_resp_o  ( axi_lite_resp ), // AXI4-Lite response struct
    .wr_active_o,                   // AXI write active
    .rd_active_o,                   // AXI read active
    .reg_d_i,                       // Register load values
    .reg_load_i,                    // Register load enable
    .reg_q_o                        // Register state
  );
  // Validate parameters.
  // pragma translate_off
  `ifndef VERILATOR
    initial begin: p_assertions
      assert (AXI_ADDR_WIDTH == $bits(slv.aw_addr))
          else $fatal(1, "AXI_ADDR_WIDTH does not match slv interface!");
      assert (AXI_DATA_WIDTH == $bits(slv.w_data))
          else $fatal(1, "AXI_DATA_WIDTH does not match slv interface!");
    end
  `endif
  // pragma translate_on
endmodule
