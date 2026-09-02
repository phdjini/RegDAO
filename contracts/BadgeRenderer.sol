// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title BadgeRenderer (v2 — 6단계 등급 + 포인트 표시)
 * @notice RegDAO 배지의 온체인 SVG 아트워크 및 ERC-721 메타데이터(tokenURI)를 생성한다.
 *
 *         Tier 0 Observer       - 무채색 방패만
 *         Tier 1 Member-Bronze  - 동색 금테 방패 + 리본
 *         Tier 2 Member-Silver  - 은색 금테 방패 + 리본
 *         Tier 3 Member-Gold    - 금색 금테 방패 + 리본 + 이중 테두리
 *         Tier 4 Council        - 4방향 광선 + 이중 금테
 *         Tier 5 Elder          - 8방향 광선 + 월계 장식 + 삼중 금테 (풀버전)
 */
contract BadgeRenderer {
    function tokenURI(uint256 tokenId, uint8 tier, uint256 points) external pure returns (string memory) {
        string memory tierName = _tierName(tier);
        string memory svg = _svg(tier);
        string memory image = string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svg))));

        bytes memory json = abi.encodePacked(
            '{"name":"RegDAO Badge #', _toString(tokenId), ' - ', tierName, '",',
            '"description":"RegDAO badge is a non-transferable (soulbound) reputation credential. ',
            'Points accumulate through peer endorsement, policy-board contributions, and ',
            'governance-verified achievement; tier is derived from accumulated points.",',
            '"attributes":[{"trait_type":"Tier","value":"', tierName, '"},',
            '{"trait_type":"Points","value":', _toString(points), '}],',
            '"image":"', image, '"}'
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    function _tierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 0) return "Observer";
        if (tier == 1) return "Member-Bronze";
        if (tier == 2) return "Member-Silver";
        if (tier == 3) return "Member-Gold";
        if (tier == 4) return "Council";
        return "Elder";
    }

    function _shieldColor(uint8 tier) internal pure returns (string memory) {
        if (tier == 1) return "#96793B"; // bronze
        if (tier == 2) return "#B9B9B9"; // silver
        return "#D4B15C";                // gold (tier 3+)
    }

    function _svg(uint8 tier) internal pure returns (string memory) {
        if (tier == 0) return _wrap(_shieldBase(), _cornerBadge(0));
        if (tier == 1 || tier == 2) {
            return _wrap(string(abi.encodePacked(_shieldGilt(_shieldColor(tier)), _ribbon())), _cornerBadge(tier));
        }
        if (tier == 3) {
            return _wrap(
                string(abi.encodePacked(_shieldGilt(_shieldColor(3)), _innerBorder(), _ribbon())),
                _cornerBadge(3)
            );
        }
        if (tier == 4) {
            return _wrap(
                string(abi.encodePacked(_rays4(), _shieldGilt(_shieldColor(4)), _innerBorder(), _ribbon())),
                _cornerBadge(4)
            );
        }
        return _wrap(
            string(abi.encodePacked(_rays8(), _ring(), _jewels(), _shieldGilt(_shieldColor(5)), _innerBorder(), _outerGiltBorder(), _wreath(), _ribbonWide())),
            _cornerBadge(5)
        );
    }

    function _wrap(string memory content, string memory corner) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 250 260">',
            '<rect width="250" height="260" fill="#EEEAE0"/>',
            '<g transform="translate(125,130)">', content, corner, '</g></svg>'
        ));
    }

    function _shieldBase() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<path d="M -45,-55 L 45,-55 L 45,10 Q 45,45 0,65 Q -45,45 -45,10 Z" fill="#5B5A52"/>',
            '<text x="0" y="10" text-anchor="middle" font-size="34" font-weight="500" fill="#EEEAE0" font-family="Georgia, serif">R</text>'
        ));
    }

    function _shieldGilt(string memory stroke) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<path d="M -45,-55 L 45,-55 L 45,10 Q 45,45 0,65 Q -45,45 -45,10 Z" fill="#121E30" stroke="', stroke, '" stroke-width="2.5"/>',
            '<text x="0" y="6" text-anchor="middle" font-size="30" font-weight="500" fill="#EEE3C7" font-family="Georgia, serif">R</text>'
        ));
    }

    function _innerBorder() internal pure returns (string memory) {
        return '<path d="M -40,-49 L 40,-49 L 40,9 Q 40,39 0,57 Q -40,39 -40,9 Z" fill="none" stroke="#0A1420" stroke-width="1"/>';
    }

    function _outerGiltBorder() internal pure returns (string memory) {
        return '<path d="M -35,-43 L 35,-43 L 35,8 Q 35,34 0,49 Q -35,34 -35,8 Z" fill="none" stroke="#D4B15C" stroke-width="1"/>';
    }

    function _ribbon() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<polygon points="-60,74 60,74 70,88 60,102 -60,102 -70,88" fill="#121E30" stroke="#D4B15C" stroke-width="1.5"/>',
            '<text x="0" y="94" text-anchor="middle" font-size="14" letter-spacing="2" fill="#D4B15C" font-family="Georgia, serif">REGDAO</text>'
        ));
    }

    function _ribbonWide() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<polygon points="-82,74 82,74 94,88 82,102 -82,102 -94,88" fill="#121E30" stroke="#D4B15C" stroke-width="1.5"/>',
            '<text x="0" y="94" text-anchor="middle" font-size="16" letter-spacing="3" fill="#D4B15C" font-family="Georgia, serif">REGDAO</text>'
        ));
    }

    function _rays4() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<polygon points="100,0 68,8 68,-8" fill="#B08D3E"/>',
            '<polygon points="0,100 -8,68 8,68" fill="#B08D3E"/>',
            '<polygon points="-100,0 -68,-8 -68,8" fill="#B08D3E"/>',
            '<polygon points="0,-100 8,-68 -8,-68" fill="#B08D3E"/>'
        ));
    }

    function _rays8() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<polygon points="100,0 68,8 68,-8" fill="#7A5F2A"/>',
            '<polygon points="70.7,70.7 42.4,53.8 53.8,42.4" fill="#B08D3E"/>',
            '<polygon points="0,100 -8,68 8,68" fill="#7A5F2A"/>',
            '<polygon points="-70.7,70.7 -53.8,42.4 -42.4,53.8" fill="#B08D3E"/>',
            '<polygon points="-100,0 -68,-8 -68,8" fill="#7A5F2A"/>',
            '<polygon points="-70.7,-70.7 -42.4,-53.8 -53.8,-42.4" fill="#B08D3E"/>',
            '<polygon points="0,-100 8,-68 -8,-68" fill="#7A5F2A"/>',
            '<polygon points="70.7,-70.7 53.8,-42.4 42.4,-53.8" fill="#B08D3E"/>'
        ));
    }

    function _ring() internal pure returns (string memory) {
        return '<circle r="62" fill="none" stroke="#B08D3E" stroke-width="1"/>';
    }

    function _jewels() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<polygon points="-20,-92 -14,-86 -20,-80 -26,-86" fill="#D4B15C"/>',
            '<polygon points="0,-96 6,-90 0,-84 -6,-90" fill="#D4B15C"/>',
            '<polygon points="20,-92 26,-86 20,-80 14,-86" fill="#D4B15C"/>'
        ));
    }

    function _wreath() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<ellipse cx="-28" cy="-2" rx="10" ry="4" fill="#7A5F2A" transform="rotate(-30 -28 -2)"/>',
            '<ellipse cx="-20" cy="8" rx="9" ry="3.5" fill="#7A5F2A" transform="rotate(-15 -20 8)"/>',
            '<ellipse cx="28" cy="-2" rx="10" ry="4" fill="#7A5F2A" transform="rotate(30 28 -2)"/>',
            '<ellipse cx="20" cy="8" rx="9" ry="3.5" fill="#7A5F2A" transform="rotate(15 20 8)"/>'
        ));
    }

    function _cornerBadge(uint8 tier) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<circle cx="50" cy="-58" r="16" fill="#A63D2F"/>',
            '<text x="50" y="-52" text-anchor="middle" font-size="15" font-weight="500" fill="#EEEAE0" font-family="sans-serif">',
            _toString(tier), '</text>'
        ));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
