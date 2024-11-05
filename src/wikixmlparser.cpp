#include "wikixmlparser.h"
#include "rapidxml.hpp"
#include <iostream>
#include <string>

#define PARSE_PAGE_ERROR { false, 0, nullptr, 0, nullptr, 0 }

WikiParseResult parsePage(const char* rawXmlEntry)
{
    rapidxml::xml_document<> doc;

    const char* log_prefix = "[XML Dump Parsing] ";

    try {
        doc.parse<rapidxml::parse_fastest>((char*)rawXmlEntry);
    } catch (const std::exception& e) {
        std::cout << log_prefix << "XML parse error: " << e.what() << std::endl;
        return PARSE_PAGE_ERROR;
    }

    rapidxml::xml_node<>* pageNode = doc.first_node();
    if (!pageNode)
        return PARSE_PAGE_ERROR;

    bool is_redirect;
    if (pageNode->first_node("redirect") == nullptr) {
        is_redirect = false;
    } else {
        is_redirect = true;
    }

    // we only want 'mainspace' or ns='0' articles
    rapidxml::xml_node<>* namespaceNode = pageNode->first_node("ns");
    if (!namespaceNode) {
        std::cout << log_prefix << "No namespace found" << std::endl;
        return PARSE_PAGE_ERROR;
    }

    auto namespace_string = std::string(namespaceNode->value(), namespaceNode->value_size());
    uint8_t ns;
    try {
        ns = std::stoi(namespace_string);
    } catch (const std::exception) {
        std::cout << log_prefix << "Namespace couldn't be parsed to uint8_t" << std::endl;
    }

    rapidxml::xml_node<>* titleNode = pageNode->first_node("title");
    if (!titleNode)
        return PARSE_PAGE_ERROR;

    rapidxml::xml_node<>* revNode = pageNode->first_node("revision");
    if (!revNode)
        return PARSE_PAGE_ERROR;

    rapidxml::xml_node<>* textNode = revNode->first_node("text");
    if (!textNode)
        return PARSE_PAGE_ERROR;

    return {
        is_redirect,
        ns,
        titleNode->value(),
        titleNode->value_size(),
        textNode->value(),
        textNode->value_size(),
    };
}
