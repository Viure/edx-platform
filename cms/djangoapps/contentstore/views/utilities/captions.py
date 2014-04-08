

"""
Views related to operations on course objects
"""
import json


from django.contrib.auth.decorators import login_required
from django_future.csrf import ensure_csrf_cookie
from django.core.exceptions import PermissionDenied
from django.http import HttpResponseBadRequest, HttpResponseNotFound
from edxmako.shortcuts import render_to_response
from xmodule.modulestore.django import modulestore, loc_mapper
from models.settings.course_grading import CourseGradingModel

from ..access import has_course_access
from ..component import (
    OPEN_ENDED_COMPONENT_TYPES, NOTE_COMPONENT_TYPES,
    ADVANCED_COMPONENT_POLICY_KEY)

from xmodule.modulestore.locator import BlockUsageLocator
from xmodule.modulestore import Location
from xmodule.contentstore.content import StaticContent
from xmodule.contentstore.django import contentstore
from xmodule.exceptions import NotFoundError
import logging
import copy
from django.conf import settings
import requests
from util.json_request import JsonResponse
from xmodule.video_module.transcripts_utils import (
                                  GetTranscriptsFromYouTubeException,
                                  download_youtube_subs)

from ..transcripts_ajax import get_transcripts_presence


log = logging.getLogger(__name__)

__all__ = ['utility_captions_handler']


def _get_locator_and_course(package_id, branch, version_guid, block_id, user, depth=0):
    """
    Internal method used to calculate and return the locator and course module
    for the view functions in this file.
    """
    locator = BlockUsageLocator(package_id=package_id, branch=branch, version_guid=version_guid, block_id=block_id)
    if not has_course_access(user, locator):
        raise PermissionDenied()
    course_location = loc_mapper().translate_locator_to_location(locator)
    course_module = modulestore().get_item(course_location, depth=depth)
    return locator, course_module


# pylint: disable=unused-argument
@login_required
def utility_captions_handler(request, tag=None, package_id=None, branch=None, version_guid=None, block=None, utilities_index=None):
    """
    The restful handler for course specific requests.
    It provides the course tree with the necessary information for identifying and labeling the parts. The root
    will typically be a 'course' object but may not be especially as we support modules.

    GET
        html: return course listing page if not given a course id
        html: return html page overview for the given course if given a course id
        json: return json representing the course branch's index entry as well as dag w/ all of the children
        replaced w/ json docs where each doc has {'_id': , 'display_name': , 'children': }
    POST
        json: create a course, return resulting json
        descriptor (same as in GET course/...). Leaving off /branch/draft would imply create the course w/ default
        branches. Cannot change the structure contents ('_id', 'display_name', 'children') but can change the
        index entry.
    PUT
        json: update this course (index entry not xblock) such as repointing head, changing display name, org,
        package_id, prettyid. Return same json as above.
    DELETE
        json: delete this branch from this course (leaving off /branch/draft would imply delete the course)
    """
    response_format = request.REQUEST.get('format', 'html')
    if response_format == 'json' or 'application/json' in request.META.get('HTTP_ACCEPT', 'application/json'):
        if request.method == 'POST':  # not sure if this is only post. If one will have ids, it goes after access
            if request.POST.get('action') == 'update':
                return json_update_videos(request, json.loads(request.POST.get('update_array', '[]')))
            else:
                return get_video_status(json.loads(request.POST.get('video')))
        else:
            return HttpResponseBadRequest()
    elif request.method == 'GET':  # assume html
        return course_index(request, package_id, branch, version_guid, block)
    else:
        return HttpResponseNotFound()


@login_required
@ensure_csrf_cookie
def json_update_videos(request, locations):
    """
    Display an editable course overview.

    org, course, name: Attributes of the Location for the item to edit
    """
    results = {}

    for key in locations:
        try:
            item = modulestore().get_item(key)
            download_youtube_subs({1.0: item.youtube_id_1_0}, item, settings)
            item.sub = item.youtube_id_1_0
            item.save_with_metadata(request.user)
            results[key] = True
        except GetTranscriptsFromYouTubeException as e:
            results[key] = False

    return JsonResponse(results)


@login_required
@ensure_csrf_cookie
def json_video_data(request, package_id, branch, version_guid, block):
    """
    Display an editable course overview.

    org, course, name: Attributes of the Location for the item to edit
    """
    locator, course = _get_locator_and_course(
        package_id, branch, version_guid, block, request.user, depth=3
    )

    unit_dict = get_videos(course)
    return JsonResponse(unit_dict)


@login_required
@ensure_csrf_cookie
def course_index(request, package_id, branch, version_guid, block):
    """
    Display an editable course overview.

    org, course, name: Attributes of the Location for the item to edit
    """
    locator, course = _get_locator_and_course(
        package_id, branch, version_guid, block, request.user, depth=3
    )
    sections = course.get_children()

    return render_to_response('captions.html',
        {
            'videos': get_videos(course),
            'context_course': course,
            'new_unit_category': 'vertical',
            'course_graders': json.dumps(CourseGradingModel.fetch(locator).graders),
            'locator': locator,
        }
    )


def get_video_status(video_meta):
    component = modulestore().get_item(video_meta['location'])
    video_meta['status'] = get_transcript_status(component)
    return JsonResponse(video_meta)


def get_videos(course):
    unit_dict = {}
    video_list = []
    for section in course.get_children():
        for subsection in section.get_children():
            for unit in subsection.get_children():
                for component in unit.get_children():
                    if component.location.category == 'video':
                        video_list.append({'name': component.display_name_with_default, 'location': str(component.location)})
    return video_list


def get_transcript_status(item):
    transcripts_presence = {
        'html5_local': [],
        'html5_equal': False,
        'is_youtube_mode': False,
        'youtube_local': False,
        'youtube_server': False,
        'youtube_diff': True,
        'current_item_subs': None,
        'status': 'Error',
    }

    videos = {'youtube': item.youtube_id_1_0}
    html5 = {}
    for url in item.html5_sources:
        name = url.split('/')[-1].split('.mp4')[0]
        html5[name] = 'html5'
    videos['html5'] = html5

    transcripts_presence = get_transcripts_presence(videos, item, transcripts_presence)
    status = transcripts_presence['status'] == 'Success' and not transcripts_presence['youtube_diff']
    return status
