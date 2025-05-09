// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_COMPILER_BACKEND_LINEARSCAN_H_
#define RUNTIME_VM_COMPILER_BACKEND_LINEARSCAN_H_

#if defined(DART_PRECOMPILED_RUNTIME)
#error "AOT runtime should not use compiler sources (including header files)"
#endif  // defined(DART_PRECOMPILED_RUNTIME)

#include "vm/compiler/backend/flow_graph.h"
#include "vm/compiler/backend/il.h"
#include "vm/growable_array.h"

namespace dart {

class AllocationFinger;
class FlowGraph;
class LiveRange;
class UseInterval;
class UsePosition;

class ReachingDefs : public ValueObject {
 public:
  explicit ReachingDefs(const FlowGraph& flow_graph)
      : flow_graph_(flow_graph), phis_(10) {}

  BitVector* Get(PhiInstr* phi);

 private:
  void AddPhi(PhiInstr* phi);
  void Compute();

  const FlowGraph& flow_graph_;
  GrowableArray<PhiInstr*> phis_;
};

class SSALivenessAnalysis : public LivenessAnalysis {
 public:
  explicit SSALivenessAnalysis(const FlowGraph* flow_graph)
      : LivenessAnalysis(flow_graph, flow_graph->max_vreg()),
        graph_entry_(flow_graph->graph_entry()) {}

 private:
  // Compute initial values for live-out, kill and live-in sets.
  virtual void ComputeInitialSets();

  GraphEntryInstr* graph_entry_;
};

// Forward.
struct ExtraLoopInfo;

class FlowGraphAllocator : public ValueObject {
 public:
  // Number of stack slots needed for a fpu register spill slot.
  static constexpr intptr_t kDoubleSpillFactor =
      kDoubleSize / compiler::target::kWordSize;

  explicit FlowGraphAllocator(const FlowGraph& flow_graph,
                              bool intrinsic_mode = false);

  void AllocateRegisters();

  // Map a virtual register number to its live range.
  LiveRange* GetLiveRange(intptr_t vreg);

  DART_FORCE_INLINE static void SetLifetimePosition(Instruction* instr,
                                                    intptr_t pos) {
    instr->SetPassSpecificId(CompilerPass::kAllocateRegisters, pos);
  }

  DART_FORCE_INLINE static bool HasLifetimePosition(Instruction* instr) {
    return instr->HasPassSpecificId(CompilerPass::kAllocateRegisters);
  }

  DART_FORCE_INLINE static intptr_t GetLifetimePosition(
      const Instruction* instr) {
    return instr->GetPassSpecificId(CompilerPass::kAllocateRegisters);
  }

 private:
  void CollectRepresentations();

  // Visit blocks in the code generation order (reverse post order) and
  // linearly assign consequent lifetime positions to every instruction.
  // We assign position as follows:
  //
  //    2 * n     - even position corresponding to instruction's start;
  //
  //    2 * n + 1 - odd position corresponding to instruction's end;
  //
  // Having two positions per instruction allows us to capture non-trivial
  // shapes of use intervals: e.g. by placing a use at the start or the
  // end position we can distinguish between instructions that need value
  // at the register only at their start and those instructions that
  // need value in the register until the end of instruction's body.
  // Register allocator can perform splitting of live ranges at any position.
  // An implicit ParallelMove will be inserted by ConnectSplitSiblings where
  // required to resolve data flow between split siblings when allocation
  // is finished.
  // For specific examples see comments inside ProcessOneInstruction.
  // Additionally creates parallel moves at the joins' predecessors
  // that will be used for phi resolution.
  void NumberInstructions();
  Instruction* InstructionAt(intptr_t pos) const;
  BlockEntryInstr* BlockEntryAt(intptr_t pos) const;
  bool IsBlockEntry(intptr_t pos) const;
  bool IsCatchBlockEntry(intptr_t pos) const;

  LiveRange* MakeLiveRangeForTemporary();

  // Visit instructions in the postorder and build live ranges for
  // all SSA values.
  void BuildLiveRanges();

  Instruction* ConnectOutgoingPhiMoves(BlockEntryInstr* block,
                                       BitVector* interference_set);
  void ProcessEnvironmentUses(BlockEntryInstr* block, Instruction* current);
  void ProcessMaterializationUses(BlockEntryInstr* block,
                                  const intptr_t block_start_pos,
                                  const intptr_t use_pos,
                                  MaterializeObjectInstr* mat);
  void ProcessOneInput(BlockEntryInstr* block,
                       intptr_t pos,
                       Location* in_ref,
                       Value* input,
                       intptr_t vreg,
                       RegisterSet* live_registers);
  void ProcessOneOutput(BlockEntryInstr* block,
                        intptr_t pos,
                        Location* out,
                        Definition* def,
                        intptr_t vreg,
                        bool output_same_as_first_input,
                        Location* in_ref,
                        Definition* input,
                        intptr_t input_vreg,
                        BitVector* interference_set);
  void ProcessOneInstruction(BlockEntryInstr* block,
                             Instruction* instr,
                             BitVector* interference_set);

  static constexpr intptr_t kNormalEntryPos = 2;

  void CompleteRange(Definition* defn, LiveRange* range);
  void ProcessInitialDefinition(Definition* defn,
                                LiveRange* range,
                                BlockEntryInstr* block,
                                intptr_t initial_definition_index,
                                bool second_location_for_definition = false);
  void ConnectIncomingPhiMoves(JoinEntryInstr* join);
  void BlockLocation(Location loc, intptr_t from, intptr_t to);
  void BlockRegisterLocation(Location loc,
                             intptr_t from,
                             intptr_t to,
                             bool* blocked_registers,
                             LiveRange** blocking_ranges);

  void BlockCpuRegisters(intptr_t registers, intptr_t from, intptr_t to);

  void BlockFpuRegisters(intptr_t fpu_registers, intptr_t from, intptr_t to);

  intptr_t NumberOfRegisters() const { return number_of_registers_; }

  // Test if [param] is live only after [catch_entry].
  bool IsLiveAfterCatchEntry(CatchBlockEntryInstr* catch_entry,
                             ParameterInstr* param);

  // Find all safepoints that are covered by this live range.
  void AssignSafepoints(Definition* defn, LiveRange* range);

  void PrepareForAllocation(Location::Kind register_kind,
                            intptr_t number_of_registers,
                            const GrowableArray<LiveRange*>& unallocated,
                            LiveRange** blocking_ranges,
                            bool* blocked_registers);

  // Process live ranges sorted by their start and assign registers
  // to them
  void AllocateUnallocatedRanges();
  void AdvanceActiveIntervals(const intptr_t start);

  void RemoveFrameIfNotNeeded();

  // Connect split siblings over non-linear control flow edges.
  void ResolveControlFlow();

  void ScheduleParallelMoves();

  // Returns true if the target location is the spill slot for the given range.
  bool TargetLocationIsSpillSlot(LiveRange* range, Location target);

  // Update location slot corresponding to the use with location allocated for
  // the use's live range.
  void ConvertUseTo(UsePosition* use, Location loc);
  void ConvertAllUses(LiveRange* range);

  // Add live range to the list of unallocated live ranges to be processed
  // by the allocator.
  void AddToUnallocated(LiveRange* range);
  void CompleteRange(LiveRange* range, Location::Kind kind);
#if defined(DEBUG)
  bool UnallocatedIsSorted();
#endif

  // Try to find a free register for an unallocated live range.
  bool AllocateFreeRegister(LiveRange* unallocated);

  // Try to find a register that can be used by a given live range.
  // If all registers are occupied consider evicting interference for
  // a register that is going to be used as far from the start of
  // the unallocated live range as possible.
  void AllocateAnyRegister(LiveRange* unallocated);

  // Returns true if the given range has only unconstrained uses in
  // the given loop.
  bool RangeHasOnlyUnconstrainedUsesInLoop(LiveRange* range, intptr_t loop_id);

  // Returns true if there is a register blocked by a range that
  // has only unconstrained uses in the loop. Such range is a good
  // eviction candidate when allocator tries to allocate loop phi.
  // Spilling loop phi will have a bigger negative impact on the
  // performance because it introduces multiple operations with memory
  // inside the loop body and on the back edge.
  bool HasCheapEvictionCandidate(LiveRange* phi_range);
  bool IsCheapToEvictRegisterInLoop(LoopInfo* loop_info, intptr_t reg);

  // Assign selected non-free register to an unallocated live range and
  // evict any interference that can be evicted by splitting and spilling
  // parts of interfering live ranges.  Place non-spilled parts into
  // the list of unallocated ranges.
  void AssignNonFreeRegister(LiveRange* unallocated, intptr_t reg);
  bool EvictIntersection(LiveRange* allocated, LiveRange* unallocated);
  void RemoveEvicted(intptr_t reg, intptr_t first_evicted);

  // Find first intersection between unallocated live range and
  // live ranges currently allocated to the given register.
  intptr_t FirstIntersectionWithAllocated(intptr_t reg, LiveRange* unallocated);

  bool UpdateFreeUntil(intptr_t reg,
                       LiveRange* unallocated,
                       intptr_t* cur_free_until,
                       intptr_t* cur_blocked_at);

  // Split given live range in an optimal position between given positions.
  LiveRange* SplitBetween(LiveRange* range, intptr_t from, intptr_t to);

  // Find a spill slot that can be used by the given live range.
  void AllocateSpillSlotFor(LiveRange* range);

  // Allocate spill slot for synthetic :suspend_state variable.
  void AllocateSpillSlotForSuspendState();

  // Mark synthetic :suspend_state variable as object in stackmaps
  // at all safepoints.
  void UpdateStackmapsForSuspendState();

  // Returns true if [defn] is an OsrEntry parameter
  // corresponding to a synthetic :suspend_state variable.
  bool IsSuspendStateParameter(Definition* defn);

  // Allocates spill slot [slot_index] for the initial definition of
  // OsrEntry (Parameter or Constant).
  void AllocateSpillSlotForInitialDefinition(intptr_t slot_index,
                                             intptr_t range_end);

  // Allocate the given live range to a spill slot.
  void Spill(LiveRange* range);

  // Spill the given live range from the given position onwards.
  void SpillAfter(LiveRange* range, intptr_t from);

  // Spill the given live range from the given position until some
  // position preceding the to position.
  void SpillBetween(LiveRange* range, intptr_t from, intptr_t to);

  // Mark the live range as a live object pointer at all safepoints
  // contained in the range.
  void MarkAsObjectAtSafepoints(LiveRange* range);

  MoveOperands* AddMoveAt(intptr_t pos, Location to, Location from);

  Location MakeRegisterLocation(intptr_t reg) {
    return Location::MachineRegisterLocation(register_kind_, reg);
  }

  void SplitInitialDefinitionAt(LiveRange* range,
                                intptr_t pos,
                                Location::Kind kind);

  // Returns true if |defn| is not used after |current|.
  //
  // Only works during range construction (e.g. ProcessOneInstruction).
  bool IsDeadAfterCurrentInstruction(BlockEntryInstr* block,
                                     Instruction* current,
                                     Definition* defn);

  void PrintLiveRanges();

  // Assign locations for each outgoing argument. Outgoing argumenst are
  // currently stored at the top of the stack in direct order (last argument
  // at the top of the stack).
  void AllocateOutgoingArguments();

  const FlowGraph& flow_graph_;

  ReachingDefs reaching_defs_;

  // Representation for SSA values indexed by SSA temp index.
  GrowableArray<Representation> value_representations_;

  const GrowableArray<BlockEntryInstr*>& block_order_;
  const GrowableArray<BlockEntryInstr*>& postorder_;

  // Mapping between lifetime positions and instructions.
  GrowableArray<Instruction*> instructions_;

  // Mapping between lifetime positions and block entries.
  GrowableArray<BlockEntryInstr*> block_entries_;

  // Mapping between loops and additional information.
  GrowableArray<ExtraLoopInfo*> extra_loop_info_;

  SSALivenessAnalysis liveness_;

  // Number of virtual registers.  Currently equal to the number of
  // SSA values.
  const intptr_t vreg_count_;

  // LiveRanges corresponding to SSA values.
  GrowableArray<LiveRange*> live_ranges_;

  GrowableArray<LiveRange*> unallocated_cpu_;
  GrowableArray<LiveRange*> unallocated_fpu_;

  LiveRange* cpu_regs_[kNumberOfCpuRegisters];
  LiveRange* fpu_regs_[kNumberOfFpuRegisters];

  bool blocked_cpu_registers_[kNumberOfCpuRegisters];
  bool blocked_fpu_registers_[kNumberOfFpuRegisters];

#if defined(DEBUG)
  GrowableArray<LiveRange*> temporaries_;
#endif

  // List of spilled live ranges.
  GrowableArray<LiveRange*> spilled_;

  // List of instructions containing calls.
  GrowableArray<Instruction*> safepoints_;

  Location::Kind register_kind_;

  intptr_t number_of_registers_;

  // Per register lists of allocated live ranges.  Contain only those
  // ranges that can be affected by future allocation decisions.
  // Those live ranges that end before the start of the current live range are
  // removed from the list and will not be affected.
  // The length of both arrays is 'number_of_registers_'
  GrowableArray<ZoneGrowableArray<LiveRange*>*> registers_;

  GrowableArray<bool> blocked_registers_;

  // Worklist for register allocator. Always maintained sorted according
  // to ShouldBeAllocatedBefore predicate.
  GrowableArray<LiveRange*> unallocated_;

  // List of used spill slots. Contains positions after which spill slots
  // become free and can be reused for allocation.
  GrowableArray<intptr_t> spill_slots_;

  // For every used spill slot contains a flag determines whether it is
  // QuadSpillSlot to ensure that indexes of quad and double spill slots
  // are disjoint.
  GrowableArray<bool> quad_spill_slots_;

  // Track whether a spill slot is expected to hold a tagged or untagged value.
  // This is used to keep tagged and untagged spill slots disjoint. See bug
  // #18955 for details.
  GrowableArray<bool> untagged_spill_slots_;

  intptr_t cpu_spill_slot_count_;

  const bool intrinsic_mode_;

  DISALLOW_COPY_AND_ASSIGN(FlowGraphAllocator);
};

// UsePosition represents a single use of an SSA value by some instruction.
// It points to a location slot which either tells register allocator
// where instruction expects the value (if slot contains a fixed location) or
// asks register allocator to allocate storage (register or spill slot) for
// this use with certain properties (if slot contains an unallocated location).
class UsePosition : public ZoneAllocated {
 public:
  UsePosition(intptr_t pos, UsePosition* next, Location* location_slot)
      : pos_(pos), location_slot_(location_slot), hint_(nullptr), next_(next) {
    ASSERT(location_slot != nullptr);
  }

  Location* location_slot() const { return location_slot_; }
  void set_location_slot(Location* location_slot) {
    location_slot_ = location_slot;
  }

  Location hint() const {
    ASSERT(HasHint());
    return *hint_;
  }

  void set_hint(Location* hint) { hint_ = hint; }

  bool HasHint() const { return (hint_ != nullptr) && !hint_->IsUnallocated(); }

  void set_next(UsePosition* next) { next_ = next; }
  UsePosition* next() const { return next_; }

  intptr_t pos() const { return pos_; }

 private:
  const intptr_t pos_;
  Location* location_slot_;
  Location* hint_;
  UsePosition* next_;

  DISALLOW_COPY_AND_ASSIGN(UsePosition);
};

// UseInterval represents a holeless half open interval of liveness for a given
// SSA value: [start, end) in terms of lifetime positions that
// NumberInstructions assigns to instructions.  Register allocator has to keep
// a value live in the register or in a spill slot from start position and until
// the end position.  The interval can cover zero or more uses.
// Note: currently all uses of the same SSA value are linked together into a
// single list (and not split between UseIntervals).
class UseInterval : public ZoneAllocated {
 public:
  UseInterval(intptr_t start, intptr_t end, UseInterval* next)
      : start_(start), end_(end), next_(next) {}

  void Print();

  intptr_t start() const { return start_; }
  intptr_t end() const { return end_; }
  UseInterval* next() const { return next_; }

  bool Contains(intptr_t pos) const {
    return (start() <= pos) && (pos < end());
  }

  // Return the smallest position that is covered by both UseIntervals or
  // kIllegalPosition if intervals do not intersect.
  intptr_t Intersect(UseInterval* other);

 private:
  friend class LiveRange;

  intptr_t start_;
  intptr_t end_;
  UseInterval* next_;

  DISALLOW_COPY_AND_ASSIGN(UseInterval);
};

// AllocationFinger is used to keep track of currently active position
// for the register allocator and cache lookup results.
class AllocationFinger : public ValueObject {
 public:
  AllocationFinger()
      : first_pending_use_interval_(nullptr),
        first_register_use_(nullptr),
        first_register_beneficial_use_(nullptr),
        first_hinted_use_(nullptr) {}

  void Initialize(LiveRange* range);
  void UpdateAfterSplit(intptr_t first_use_after_split_pos);
  bool Advance(intptr_t start);

  UseInterval* first_pending_use_interval() const {
    return first_pending_use_interval_;
  }

  Location FirstHint();
  UsePosition* FirstRegisterUse(intptr_t after_pos);
  UsePosition* FirstRegisterBeneficialUse(intptr_t after_pos);
  UsePosition* FirstInterferingUse(intptr_t after_pos);

 private:
  UseInterval* first_pending_use_interval_;
  UsePosition* first_register_use_;
  UsePosition* first_register_beneficial_use_;
  UsePosition* first_hinted_use_;

  DISALLOW_COPY_AND_ASSIGN(AllocationFinger);
};

class SafepointPosition : public ZoneAllocated {
 public:
  SafepointPosition(intptr_t pos, LocationSummary* locs)
      : pos_(pos), locs_(locs), next_(nullptr) {}

  void set_next(SafepointPosition* next) { next_ = next; }
  SafepointPosition* next() const { return next_; }

  intptr_t pos() const { return pos_; }

  LocationSummary* locs() const { return locs_; }

 private:
  const intptr_t pos_;
  LocationSummary* const locs_;

  SafepointPosition* next_;
};

// LiveRange represents a sequence of UseIntervals for a given SSA value.
class LiveRange : public ZoneAllocated {
 public:
  explicit LiveRange(intptr_t vreg, Representation rep)
      : vreg_(vreg),
        representation_(rep),
        assigned_location_(),
        spill_slot_(),
        uses_(nullptr),
        first_use_interval_(nullptr),
        last_use_interval_(nullptr),
        first_safepoint_(nullptr),
        last_safepoint_(nullptr),
        next_sibling_(nullptr),
        has_only_any_uses_in_loops_(0),
        is_loop_phi_(false),
        finger_() {}

  intptr_t vreg() const { return vreg_; }
  Representation representation() const { return representation_; }
  LiveRange* next_sibling() const { return next_sibling_; }
  UsePosition* first_use() const { return uses_; }
  void set_first_use(UsePosition* use) { uses_ = use; }
  UseInterval* first_use_interval() const { return first_use_interval_; }
  UseInterval* last_use_interval() const { return last_use_interval_; }
  Location assigned_location() const { return assigned_location_; }
  Location* assigned_location_slot() { return &assigned_location_; }
  intptr_t Start() const { return first_use_interval()->start(); }
  intptr_t End() const { return last_use_interval()->end(); }

  SafepointPosition* first_safepoint() const { return first_safepoint_; }

  AllocationFinger* finger() { return &finger_; }

  void set_assigned_location(Location location) {
    assigned_location_ = location;
  }

  void set_spill_slot(Location spill_slot) { spill_slot_ = spill_slot; }

  void DefineAt(intptr_t pos);

  void AddSafepoint(intptr_t pos, LocationSummary* locs);

  UsePosition* AddUse(intptr_t pos, Location* location_slot);
  void AddHintedUse(intptr_t pos, Location* location_slot, Location* hint);

  void AddUseInterval(intptr_t start, intptr_t end);

  void Print();

  LiveRange* SplitAt(intptr_t pos);

  // A fast conservative check if the range might contain a given position
  // -- can return true when the range does not contain the position (e.g.,
  // the position lies in a lifetime hole between range start and end).
  bool CanCover(intptr_t pos) const {
    return (Start() <= pos) && (pos < End());
  }

  // True if the range contains the given position.
  bool Contains(intptr_t pos) const;

  Location spill_slot() const { return spill_slot_; }

  bool HasOnlyUnconstrainedUsesInLoop(intptr_t loop_id) const {
    if (loop_id < kMaxLoops) {
      const uint64_t mask = static_cast<uint64_t>(1) << loop_id;
      return (has_only_any_uses_in_loops_ & mask) != 0;
    }
    return false;
  }

  void MarkHasOnlyUnconstrainedUsesInLoop(intptr_t loop_id) {
    if (loop_id < kMaxLoops) {
      has_only_any_uses_in_loops_ |= static_cast<uint64_t>(1) << loop_id;
    }
  }

  bool is_loop_phi() const { return is_loop_phi_; }
  void mark_loop_phi() { is_loop_phi_ = true; }

  void mark_has_uses_which_require_stack() {
    has_uses_which_require_stack_ = true;
  }
  bool has_uses_which_require_stack() const {
    return has_uses_which_require_stack_;
  }

 private:
  LiveRange(intptr_t vreg,
            Representation rep,
            UsePosition* uses,
            UseInterval* first_use_interval,
            UseInterval* last_use_interval,
            SafepointPosition* first_safepoint,
            LiveRange* next_sibling)
      : vreg_(vreg),
        representation_(rep),
        assigned_location_(),
        uses_(uses),
        first_use_interval_(first_use_interval),
        last_use_interval_(last_use_interval),
        first_safepoint_(first_safepoint),
        last_safepoint_(nullptr),
        next_sibling_(next_sibling),
        has_only_any_uses_in_loops_(0),
        is_loop_phi_(false),
        finger_() {}

  const intptr_t vreg_;
  Representation representation_;
  Location assigned_location_;
  Location spill_slot_;

  UsePosition* uses_;
  UseInterval* first_use_interval_;
  UseInterval* last_use_interval_;

  SafepointPosition* first_safepoint_;
  SafepointPosition* last_safepoint_;

  LiveRange* next_sibling_;

  static constexpr intptr_t kMaxLoops = sizeof(uint64_t) * kBitsPerByte;
  uint64_t has_only_any_uses_in_loops_;
  bool is_loop_phi_;

  // Does this range have any unallocated uses with kRequiresStack policy.
  bool has_uses_which_require_stack_ = false;

  AllocationFinger finger_;

  DISALLOW_COPY_AND_ASSIGN(LiveRange);
};

}  // namespace dart

#endif  // RUNTIME_VM_COMPILER_BACKEND_LINEARSCAN_H_
