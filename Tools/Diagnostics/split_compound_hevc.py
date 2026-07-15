#!/usr/bin/env python3
"""Split an Apple compound HEVC Annex-B capture into seeded per-band streams.

Diagnostic only. Apple's first compound picture consists of one IDR followed by
three I slices with global POCs 1...3.  The first dependent update for each lower
band references both its own initial POC and POC 4.  A normal per-band decoder
does not have the full-screen POC-4 canvas, so seed POC 4 with a duplicate of
that band's clean initial I picture before appending its dependent pictures.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def split_annex_b(data: bytes) -> list[bytes]:
    starts: list[tuple[int, int]] = []
    i = 0
    while i + 3 <= len(data):
        if data[i : i + 4] == b"\x00\x00\x00\x01":
            starts.append((i, 4))
            i += 4
        elif data[i : i + 3] == b"\x00\x00\x01":
            starts.append((i, 3))
            i += 3
        else:
            i += 1
    nals: list[bytes] = []
    for index, (offset, prefix) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(data)
        nal = data[offset + prefix : end]
        if nal:
            nals.append(nal)
    return nals


def to_rbsp(nal: bytes) -> bytes:
    out = bytearray()
    zeroes = 0
    for byte in nal:
        if zeroes >= 2 and byte == 3:
            zeroes = 0
            continue
        out.append(byte)
        zeroes = zeroes + 1 if byte == 0 else 0
    return bytes(out)


def from_rbsp(rbsp: bytes) -> bytes:
    out = bytearray()
    zeroes = 0
    for byte in rbsp:
        if zeroes >= 2 and byte <= 3:
            out.append(3)
            zeroes = 0
        out.append(byte)
        zeroes = zeroes + 1 if byte == 0 else 0
    return bytes(out)


def read_bits(data: bytes, offset: int, count: int) -> int:
    value = 0
    for bit in range(offset, offset + count):
        value = (value << 1) | ((data[bit // 8] >> (7 - bit % 8)) & 1)
    return value


def read_ue(bits: list[int], offset: int) -> tuple[int, int]:
    zeroes = 0
    while bits[offset + zeroes] == 0:
        zeroes += 1
    cursor = offset + zeroes + 1
    suffix = 0
    for bit in bits[cursor : cursor + zeroes]:
        suffix = (suffix << 1) | bit
    return (1 << zeroes) - 1 + suffix, cursor + zeroes


def read_se(bits: list[int], offset: int) -> tuple[int, int]:
    code_num, cursor = read_ue(bits, offset)
    value = (code_num + 1) // 2
    return (value if code_num & 1 else -value), cursor


def write_bits(data: bytearray, offset: int, count: int, value: int) -> None:
    for index in range(count):
        bit = offset + index
        mask = 1 << (7 - bit % 8)
        if value & (1 << (count - 1 - index)):
            data[bit // 8] |= mask
        else:
            data[bit // 8] &= ~mask


def ue(value: int) -> list[int]:
    code_num = value + 1
    payload = [int(bit) for bit in f"{code_num:b}"]
    return [0] * (len(payload) - 1) + payload


def bytes_to_bits(data: bytes) -> list[int]:
    return [((byte >> (7 - bit)) & 1) for byte in data for bit in range(8)]


def bits_to_bytes(bits: list[int]) -> bytes:
    if len(bits) % 8:
        bits += [0] * (8 - len(bits) % 8)
    output = bytearray(len(bits) // 8)
    for index, bit in enumerate(bits):
        output[index // 8] |= bit << (7 - index % 8)
    return bytes(output)


def nal_type(nal: bytes) -> int:
    return (nal[0] >> 1) & 0x3F


def poc_lsb(nal: bytes) -> int | None:
    kind = nal_type(nal)
    if kind in range(16, 21):
        return 0
    if kind > 31:
        return None
    rbsp = to_rbsp(nal)
    # This capture's PPS uses: first_slice=1, pps_id=ue(0),
    # slice_type=ue(I/P), then an 11-bit POC LSB at bit 21.
    return read_bits(rbsp, 21, 11)


def with_poc_lsb(nal: bytes, poc: int) -> bytes:
    rbsp = bytearray(to_rbsp(nal))
    write_bits(rbsp, 21, 11, poc)
    return from_rbsp(bytes(rbsp))


def initial_i_as_seed(nal: bytes, poc: int) -> bytes:
    """Retag an initial I picture and retain every preceding POC in its RPS."""
    rbsp = to_rbsp(nal)
    bits = bytes_to_bits(rbsp)
    if read_bits(rbsp, 18, 3) != 0b011 or bits[32] != 0:
        raise ValueError("seed source is not the expected explicit-RPS I slice")

    # Locate the syntax immediately following the source's explicit RPS.
    cursor = 33
    if bits[cursor] != 0:  # inter_ref_pic_set_prediction_flag
        raise ValueError("unexpected predicted slice RPS")
    cursor += 1
    negative, cursor = read_ue(bits, cursor)
    positive, cursor = read_ue(bits, cursor)
    for _ in range(negative):
        _, cursor = read_ue(bits, cursor)
        cursor += 1
    for _ in range(positive):
        _, cursor = read_ue(bits, cursor)
        cursor += 1
    suffix_start = cursor

    # Parse this capture's remaining I-slice header to find byte_alignment and
    # preserve its entry-point table verbatim.
    cursor += 1  # slice_temporal_mvp_enabled_flag
    cursor += 2  # slice_sao_luma/chroma_flag
    _, cursor = read_se(bits, cursor)  # slice_qp_delta
    override = bits[cursor]
    cursor += 1
    if override:
        disabled = bits[cursor]
        cursor += 1
        if not disabled:
            _, cursor = read_se(bits, cursor)
            _, cursor = read_se(bits, cursor)
    entry_points, cursor = read_ue(bits, cursor)
    if entry_points:
        offset_len_minus1, cursor = read_ue(bits, cursor)
        cursor += entry_points * (offset_len_minus1 + 1)
    alignment_start = cursor
    if bits[cursor] != 1:
        raise ValueError("missing slice-header alignment bit")
    cursor += 1
    while cursor % 8:
        if bits[cursor] != 0:
            raise ValueError("invalid slice-header alignment padding")
        cursor += 1
    payload_start = cursor

    prefix = bits[:]
    for index in range(11):
        prefix[21 + index] = (poc >> (10 - index)) & 1
    replacement = [0] + ue(poc) + ue(0)
    for _ in range(poc):
        replacement += ue(0) + [0]
    header = prefix[:33] + replacement + bits[suffix_start:alignment_start]
    header += [1]
    while len(header) % 8:
        header.append(0)
    return from_rbsp(bits_to_bytes(header + bits[payload_start:]))


def explicit_rps_mapped_to_band(nal: bytes, band: int, poc: int) -> bytes:
    """Map logical full-canvas references to this band's latest update POC."""
    rbsp = to_rbsp(nal)
    bits = bytes_to_bits(rbsp)
    slice_type, _ = read_ue(bits, 18)
    if slice_type not in (1, 2) or bits[32] != 0:
        return nal

    cursor = 33
    if bits[cursor] != 0:
        raise ValueError("unexpected predicted slice RPS")
    cursor += 1
    negative, cursor = read_ue(bits, cursor)
    positive, cursor = read_ue(bits, cursor)
    used_references: list[int] = []
    delta = 0
    for _ in range(negative):
        minus1, cursor = read_ue(bits, cursor)
        delta -= minus1 + 1
        if bits[cursor]:
            reference_poc = poc + delta
            mapped = reference_poc - ((reference_poc - band) % 4)
            if mapped >= 0 and mapped not in used_references:
                used_references.append(mapped)
        cursor += 1
    delta = 0
    for _ in range(positive):
        minus1, cursor = read_ue(bits, cursor)
        delta += minus1 + 1
        if bits[cursor]:
            raise ValueError("unexpected positive POC reference")
        cursor += 1
    suffix_start = cursor

    # Remaining I/P-slice syntax for the captured PPS/SPS profile.
    temporal_mvp = bits[cursor]
    cursor += 1
    cursor += 2  # slice_sao_luma/chroma_flag
    if slice_type == 1:
        override = bits[cursor]
        cursor += 1
        if override:
            _, cursor = read_ue(bits, cursor)  # num_ref_idx_l0_active_minus1
        if temporal_mvp:
            raise ValueError("unexpected temporal MVP in captured P slice")
        _, cursor = read_ue(bits, cursor)  # five_minus_max_num_merge_cand
    _, cursor = read_se(bits, cursor)  # slice_qp_delta
    deblock_override = bits[cursor]
    cursor += 1
    if deblock_override:
        disabled = bits[cursor]
        cursor += 1
        if not disabled:
            _, cursor = read_se(bits, cursor)
            _, cursor = read_se(bits, cursor)
    entry_points, cursor = read_ue(bits, cursor)
    if entry_points:
        offset_len_minus1, cursor = read_ue(bits, cursor)
        cursor += entry_points * (offset_len_minus1 + 1)
    alignment_start = cursor
    if bits[cursor] != 1:
        raise ValueError("missing P-slice alignment bit")
    cursor += 1
    while cursor % 8:
        if bits[cursor] != 0:
            raise ValueError("invalid P-slice alignment padding")
        cursor += 1
    payload_start = cursor

    mapped_deltas = sorted(
        (reference - poc for reference in used_references), reverse=True)
    replacement = [0] + ue(len(mapped_deltas)) + ue(0)
    previous = 0
    for current in mapped_deltas:
        replacement += ue(previous - current - 1) + [1]
        previous = current
    header = bits[:33] + replacement + bits[suffix_start:alignment_start]
    header += [1]
    while len(header) % 8:
        header.append(0)
    return from_rbsp(bits_to_bytes(header + bits[payload_start:]))


def with_per_band_sps_rps(nal: bytes) -> bytes:
    """Replace the capture's 16 global RPS entries with per-band history.

    The offsets are validated by trace_headers for this diagnostic capture:
    num_short_term_ref_pic_sets occupies RBSP bits 207...215 and the original
    sixteen explicit sets occupy bits 216...590. During the first update cycle,
    both canvas references map to the same prior band update; steady state maps
    to the prior two band updates (-4 and -8).
    """
    rbsp = to_rbsp(nal)
    bits = bytes_to_bits(rbsp)
    if read_bits(rbsp, 207, 9) != 17:  # ue(16) codeword 000010001
        raise ValueError("unexpected SPS short-term RPS layout")
    replacement: list[int] = []
    for index in range(16):
        if index > 0:
            replacement.append(0)  # inter_ref_pic_set_prediction_flag
        deltas = (3,) if index < 8 else (3, 3)
        replacement += ue(len(deltas))  # num_negative_pics
        replacement += ue(0)  # num_positive_pics
        for delta in deltas:
            replacement += ue(delta)
            replacement.append(1)  # used_by_curr_pic_s0_flag
    return from_rbsp(bits_to_bytes(bits[:216] + replacement + bits[591:]))


def with_full_frame_sps_geometry(nal: bytes) -> bytes:
    """Expand 2976x480 coded bands to a cropped 2976x1920 canvas (1860 visible)."""
    bits = bytes_to_bits(to_rbsp(nal))
    # Width ends at bit 150; the original height and conformance flag occupy
    # bits 150...167. Chroma is 4:4:4, so a bottom crop of 60 is in luma rows.
    geometry = ue(1920) + [1] + ue(0) + ue(0) + ue(0) + ue(60)
    return from_rbsp(bits_to_bytes(bits[:150] + geometry + bits[168:]))


def locate_slice_payload(
    bits: list[int], slice_type: int, suffix_start: int, has_temporal_mvp_field: bool
) -> tuple[int, int]:
    cursor = suffix_start
    temporal_mvp = 0
    if has_temporal_mvp_field:
        temporal_mvp = bits[cursor]
        cursor += 1
    cursor += 2  # slice_sao_luma/chroma_flag
    if slice_type == 1:
        override = bits[cursor]
        cursor += 1
        if override:
            _, cursor = read_ue(bits, cursor)
        if temporal_mvp:
            raise ValueError("unexpected temporal MVP")
        _, cursor = read_ue(bits, cursor)  # five_minus_max_num_merge_cand
    _, cursor = read_se(bits, cursor)  # slice_qp_delta
    deblock_override = bits[cursor]
    cursor += 1
    if deblock_override:
        disabled = bits[cursor]
        cursor += 1
        if not disabled:
            _, cursor = read_se(bits, cursor)
            _, cursor = read_se(bits, cursor)
    entry_points, cursor = read_ue(bits, cursor)
    if entry_points:
        offset_len_minus1, cursor = read_ue(bits, cursor)
        cursor += entry_points * (offset_len_minus1 + 1)
    alignment_start = cursor
    if bits[cursor] != 1:
        raise ValueError("missing slice alignment bit")
    cursor += 1
    while cursor % 8:
        if bits[cursor] != 0:
            raise ValueError("invalid slice alignment padding")
        cursor += 1
    return alignment_start, cursor


def as_full_frame_slice(nal: bytes, band: int, global_poc: int) -> bytes:
    """Turn one Apple subframe into a standard slice of one full-frame picture."""
    source_kind = nal_type(nal)
    source_irap = source_kind in range(16, 21)
    rbsp = to_rbsp(nal)
    bits = bytes_to_bits(rbsp)

    cursor = 16
    if bits[cursor] != 1:
        raise ValueError("source is not a first slice")
    cursor += 1
    if source_irap:
        cursor += 1  # no_output_of_prior_pics_flag
    pps_id, cursor = read_ue(bits, cursor)
    slice_type, cursor = read_ue(bits, cursor)
    if pps_id != 0 or slice_type not in (1, 2):
        raise ValueError("unexpected captured slice profile")

    if not source_irap:
        cursor += 11  # slice_pic_order_cnt_lsb
        from_sps = bits[cursor]
        cursor += 1
        if from_sps:
            cursor += 4  # short_term_ref_pic_set_idx, 16 SPS sets
        else:
            if bits[cursor] != 0:
                raise ValueError("unexpected predicted slice RPS")
            cursor += 1
            negative, cursor = read_ue(bits, cursor)
            positive, cursor = read_ue(bits, cursor)
            for _ in range(negative + positive):
                _, cursor = read_ue(bits, cursor)
                cursor += 1
    suffix_start = cursor
    alignment_start, payload_start = locate_slice_payload(
        bits, slice_type, suffix_start, not source_irap)

    group = global_poc // 4
    output_irap = group == 0
    header = bits[:16]
    output_kind = 20 if output_irap else 1
    for index in range(6):
        header[1 + index] = (output_kind >> (5 - index)) & 1
    header += [1 if band == 0 else 0]
    if output_irap:
        header += [0]  # no_output_of_prior_pics_flag
    header += ue(0)  # slice_pic_parameter_set_id
    if band > 0:
        # CTU is 32x32: 2976/32 = 93 columns and each coded band is 15 rows.
        slice_segment_address = band * 93 * 15
        header += [
            (slice_segment_address >> (12 - index)) & 1 for index in range(13)
        ]
    header += ue(slice_type)
    if not output_irap:
        header += [(group >> (10 - index)) & 1 for index in range(11)]
        header += [0, 0]  # explicit RPS; no inter-RPS prediction
        references = 1 if group == 1 else 2
        header += ue(references) + ue(0)
        for _ in range(references):
            header += ue(0) + [1]  # previous full frame(s)
    output_suffix_start = suffix_start
    if output_irap and not source_irap:
        output_suffix_start += 1  # temporal MVP is absent from IRAP headers
    header += bits[output_suffix_start:alignment_start]
    header += [1]
    while len(header) % 8:
        header.append(0)
    return from_rbsp(bits_to_bytes(header + bits[payload_start:]))


def write_merged_stream(
    output_prefix: Path,
    parameter_sets: list[bytes],
    pictures: list[tuple[int, bytes]],
) -> None:
    merged_parameter_sets = [
        with_full_frame_sps_geometry(nal) if nal_type(nal) == 33 else nal
        for nal in parameter_sets
    ]
    stream = list(merged_parameter_sets)
    for poc, nal in pictures:
        try:
            stream.append(as_full_frame_slice(nal, poc % 4, poc))
        except ValueError as error:
            raise ValueError(f"POC {poc}: {error}") from error
    output = output_prefix.with_name(f"{output_prefix.name}-merged.hevc")
    output.write_bytes(annex_b(stream))
    print(f"{output}: {len(stream)} NALs, {output.stat().st_size} bytes")


def as_sparse_full_frame_slice(nal: bytes, band: int) -> bytes:
    """Place one subframe at its CTU address while preserving Apple's POC/RPS."""
    source_irap = nal_type(nal) in range(16, 21)
    bits = bytes_to_bits(to_rbsp(nal))
    cursor = 17  # after first_slice_segment_in_pic_flag
    if source_irap:
        cursor += 1
    pps_id, cursor = read_ue(bits, cursor)
    if pps_id != 0:
        raise ValueError("unexpected PPS id")
    slice_type_start = cursor
    slice_type, cursor = read_ue(bits, cursor)
    if not source_irap:
        cursor += 11
        from_sps = bits[cursor]
        cursor += 1
        if from_sps:
            cursor += 4
        else:
            cursor += 1  # inter_ref_pic_set_prediction_flag
            negative, cursor = read_ue(bits, cursor)
            positive, cursor = read_ue(bits, cursor)
            for _ in range(negative + positive):
                _, cursor = read_ue(bits, cursor)
                cursor += 1
    suffix_start = cursor
    alignment_start, payload_start = locate_slice_payload(
        bits, slice_type, suffix_start, not source_irap)

    header = bits[:16] + [1 if band == 0 else 0]
    if source_irap:
        header += [bits[17]]
    header += ue(0)
    if band > 0:
        address = band * 93 * 15
        header += [(address >> (12 - index)) & 1 for index in range(13)]
    header += bits[slice_type_start:alignment_start]
    header += [1]
    while len(header) % 8:
        header.append(0)
    return from_rbsp(bits_to_bytes(header + bits[payload_start:]))


def write_sparse_stream(
    output_prefix: Path,
    parameter_sets: list[bytes],
    pictures: list[tuple[int, bytes]],
) -> None:
    stream = [
        with_full_frame_sps_geometry(nal) if nal_type(nal) == 33 else nal
        for nal in parameter_sets
    ]
    stream.extend(as_sparse_full_frame_slice(nal, poc % 4) for poc, nal in pictures)
    output = output_prefix.with_name(f"{output_prefix.name}-sparse.hevc")
    output.write_bytes(annex_b(stream))
    print(f"{output}: {len(stream)} NALs, {output.stat().st_size} bytes")


def annex_b(nals: list[bytes]) -> bytes:
    return b"".join(b"\x00\x00\x00\x01" + nal for nal in nals)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output_prefix", type=Path)
    args = parser.parse_args()

    nals = split_annex_b(args.input.read_bytes())
    original_parameter_sets = [nal for nal in nals if nal_type(nal) in (32, 33, 34)][:3]
    parameter_sets = [
        with_per_band_sps_rps(nal) if nal_type(nal) == 33 else nal
        for nal in original_parameter_sets
    ]
    pictures = [(poc_lsb(nal), nal) for nal in nals if nal_type(nal) <= 31]
    pictures = [(poc, nal) for poc, nal in pictures if poc is not None]
    initial_idr = next(nal for poc, nal in pictures if nal_type(nal) in range(16, 21))

    write_merged_stream(args.output_prefix, original_parameter_sets, pictures)
    write_sparse_stream(args.output_prefix, original_parameter_sets, pictures)

    for band in range(4):
        own = [(poc, nal) for poc, nal in pictures if poc % 4 == band]
        stream = list(parameter_sets)
        if band == 0:
            stream.extend(nal for _, nal in own)
        else:
            initial = next(nal for poc, nal in own if poc == band)
            stream.append(initial_idr)
            stream.append(explicit_rps_mapped_to_band(initial, band, band))
            stream.extend(
                explicit_rps_mapped_to_band(nal, band, poc)
                for poc, nal in own if poc > band
            )
        output = args.output_prefix.with_name(
            f"{args.output_prefix.name}-band{band}.hevc")
        output.write_bytes(annex_b(stream))
        print(f"{output}: {len(stream)} NALs, {output.stat().st_size} bytes")


if __name__ == "__main__":
    main()
